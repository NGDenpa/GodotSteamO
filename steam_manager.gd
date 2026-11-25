extends Node
## ============================================================================
## SteamManager —— Godot 4 + GodotSteam 成就 / 统计管理单例（Autoload）
## 依赖：GodotSteam 4.x GDExtension（addons/godotsteam/）
##
## ---------------------------------------------------------------------------
## 本脚本用到的每一个 Steam.* 调用，都来自下列官方文档（可自行核对）：
##
##   [1] GodotSteam 安装（GDExtension）
##       https://godotsteam.com/howto/gdextension
##   [2] 初始化 Steam（steamInitEx / run_callbacks 的正确用法）
##       https://godotsteam.com/tutorials/initializing
##   [3] 统计与成就官方教程（本脚本整体结构来源）
##       https://godotsteam.com/tutorials/stats_achievements
##   [4] User Stats 类 API（setAchievement / getAchievement / storeStats /
##       setStatInt / setStatFloat / getStatInt / resetAllStats /
##       clearAchievement / indicateAchievementProgress / 信号 user_stats_stored）
##       https://godotsteam.com/classes/user_stats/
##   [5] Main 类（steamInitEx / run_callbacks / get_godotsteam_version）
##       https://godotsteam.com/classes/main/
##   [6] User 类（getSteamID）
##       https://godotsteam.com/classes/user/
##   [7] Friends 类（getPersonaName）
##       https://godotsteam.com/classes/friends/
##   [8] Steamworks 官方成就与统计说明（Stat 字段含义、进度型成就自动解锁）
##       https://partner.steamgames.com/doc/features/achievements
##   [9] Steamworks EResult 枚举（k_EResultOK = 1, k_EResultInvalidParam = 8）
##       https://partner.steamgames.com/doc/api/steam_api#EResult
##   [10] 官方示例游戏 Skillet（真实项目里的完整实现，可对照阅读）
##       https://codeberg.org/godotsteam/skillet
##
## 注意：官方文档里**没有** SteamManager 这个类。它只是本脚本对上述 API 的
## 一层薄封装，用来隔离「Steam 没启动 / 成就名写错 / 数值越界」这些情况。
## 每处封装的理由见对应函数的注释。
## ============================================================================

# ---------------------------------------------------------------------------
# 1. 基础配置
# ---------------------------------------------------------------------------
## Steamworks 后台的 AppID。开发阶段没有 AppID 时可用 480（Valve 的 SpaceWar 测试应用）
const STEAM_APP_ID: int = 480

## Steam 是否初始化成功。为 false 时所有 Steam 写入操作都会被跳过，
## 这样即使玩家在没开 Steam 的环境下运行，游戏也不会报错崩溃。
var steam_ready: bool = false

var steam_id: int = 0
var steam_name: String = ""

# ---------------------------------------------------------------------------
# 2. 成就与统计字典
#    key 必须和 Steamworks 后台的「API 名称」一模一样（区分大小写）
# ---------------------------------------------------------------------------

## 普通成就：只有解锁 / 未解锁两种状态
var achievements: Dictionary = {
	"ACH_FIRST_KILL": false,
	"ACH_NO_DAMAGE_BOSS": false,
	"ACH_ALL_ENDINGS": false,
}

## 统计（Stats）：进度型成就的进度值存在这里，成就本身不用写进来
## 注意：int 型用 setStatInt，float 型用 setStatFloat，写错类型 Steam 会返回 false
var statistics: Dictionary = {
	"STAT_TOTAL_KILLS": 0,      # int：累计击杀
	"STAT_TOTAL_DISTANCE": 0.0, # float：累计移动距离
}

## 哪些 stat 是 float 型（其余按 int 处理）
const FLOAT_STATS: Array[String] = ["STAT_TOTAL_DISTANCE"]

## 每个 stat 的服务端上限，必须和 Steamworks 后台填的 Max Value 一致。
## 写入前会 clamp 到这里——超范围的值会被服务端整批拒绝（k_EResultInvalidParam），
## 一旦这个 stat 又勾了 Increment Only，玩家就永久卡死无法解锁了。
const STAT_MAX: Dictionary = {
	"STAT_TOTAL_KILLS": 150,          # 后台 Max = 150，成就阈值 100（留 50% 余量）
	"STAT_TOTAL_DISTANCE": 1000000.0, # 后台 Max = 1000000
}

## Steam EResult 常用返回值
const ERESULT_OK: int = 1
const ERESULT_INVALID_PARAM: int = 8


# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------
func _init() -> void:
	# 双保险：即使 steamInitEx 的参数在老版本上不起作用，环境变量也能让 Steam 识别 AppID
	OS.set_environment("SteamAppId", str(STEAM_APP_ID))
	OS.set_environment("SteamGameId", str(STEAM_APP_ID))


func _ready() -> void:
	initialize_steam()


func _process(_delta: float) -> void:
	# 必须每帧泵一次回调，否则 setAchievement / storeStats 的结果永远收不到。
	# 如果你在 steamInitEx 里传了 embed_callbacks = true，就删掉这一行。
	if steam_ready:
		Steam.run_callbacks()


# ---------------------------------------------------------------------------
# 3. 初始化
# ---------------------------------------------------------------------------
func initialize_steam() -> void:
	var response: Dictionary = Steam.steamInitEx(STEAM_APP_ID, false)
	print("[Steam] 初始化结果: %s" % response)

	# status: 0=成功 1=其他失败 2=连不上 Steam（客户端没开）3=Steam 客户端版本过旧
	if int(response.get("status", 1)) != 0:
		push_warning("[Steam] 初始化失败，成就功能已禁用: %s" % response.get("verbal", ""))
		return

	steam_ready = true
	steam_id = Steam.getSteamID()
	steam_name = Steam.getPersonaName()
	print("[Steam] 已登录: %s (%s)" % [steam_name, str(steam_id)])

	# 监听提交结果：用于发现「统计被服务端拒绝」的情况
	Steam.user_stats_stored.connect(_on_user_stats_stored)

	# 拉取云端已有数据
	load_steam_stats()
	load_steam_achievements()


## 从 Steam 拉取统计，并与本地值做「取较大值」的合并
func load_steam_stats() -> void:
	if not steam_ready:
		return

	for key in statistics.keys():
		var steam_value = _get_steam_stat(key)
		var local_value = statistics[key]

		if _is_float_stat(key):
			if float(local_value) > float(steam_value):
				print("[Steam] %s 本地值更新（%s > %s），推送本地值" % [key, local_value, steam_value])
				set_stat_float(key, float(local_value))
			else:
				statistics[key] = float(steam_value)
		else:
			if int(local_value) > int(steam_value):
				print("[Steam] %s 本地值更新（%s > %s），推送本地值" % [key, local_value, steam_value])
				set_stat_int(key, int(local_value))
			else:
				statistics[key] = int(steam_value)

	print("[Steam] 统计数据加载完成")


## 从 Steam 拉取成就解锁状态
func load_steam_achievements() -> void:
	if not steam_ready:
		return

	for key in achievements.keys():
		var result: Dictionary = Steam.getAchievement(key)

		# ret == false 说明后台没有这个成就，多半是忘记 Publish 或 API 名字写错了
		if not bool(result.get("ret", false)):
			push_warning("[Steam] 成就不存在或未发布: %s（检查 Steamworks 后台是否已 Publish）" % key)
			continue

		achievements[key] = bool(result.get("achieved", false))

	print("[Steam] 成就状态加载完成")


# ---------------------------------------------------------------------------
# 4. 成就
# ---------------------------------------------------------------------------
## 解锁成就。解锁成功会返回 true
func unlock_achievement(key: String) -> bool:
	if not steam_ready:
		print("[Steam] Steam 未就绪，跳过成就: %s" % key)
		return false

	if not achievements.has(key):
		push_warning("[Steam] 本地字典里没有成就: %s" % key)
		return false

	# 已经解锁过就不用再发了，省一次请求
	if bool(achievements[key]):
		return true

	achievements[key] = true

	if not Steam.setAchievement(key):
		achievements[key] = false
		push_warning("[Steam] 设置成就失败: %s" % key)
		return false

	print("[Steam] 成就已解锁: %s" % key)
	store_stats()
	return true


## 查询本地缓存的解锁状态
func is_achieved(key: String) -> bool:
	return bool(achievements.get(key, false))


## 从 Steam 重新同步一次成就状态（进度型成就靠 stat 自动解锁时用）
func refresh_achievements() -> void:
	if not steam_ready:
		return
	for key in achievements.keys():
		var result: Dictionary = Steam.getAchievement(key)
		if bool(result.get("ret", false)):
			achievements[key] = bool(result.get("achieved", false))


## 弹一个「进度 3/10」的小提示（成就要在后台勾选了进度条才有效果）
func indicate_progress(key: String, current: int, target: int) -> void:
	if not steam_ready:
		return
	Steam.indicateAchievementProgress(key, current, target)


# ---------------------------------------------------------------------------
# 5. 统计
# ---------------------------------------------------------------------------
## 直接设置 int 统计的绝对值（写入并立即提交）
func set_stat_int(key: String, value: int) -> void:
	_push_stat(key, value)


## 直接设置 float 统计的绝对值（写入并立即提交）
func set_stat_float(key: String, value: float) -> void:
	_push_stat(key, value)


## 在当前值上累加 int 统计（写入并立即提交）
func add_stat_int(key: String, delta: int = 1) -> void:
	_push_stat(key, int(statistics.get(key, 0)) + delta)


## 在当前值上累加 float 统计（写入并立即提交）
func add_stat_float(key: String, delta: float) -> void:
	_push_stat(key, float(statistics.get(key, 0.0)) + delta)


func get_stat_int(key: String) -> int:
	return int(statistics.get(key, 0))


func get_stat_float(key: String) -> float:
	return float(statistics.get(key, 0.0))


## 内部：钳制 → 写内存 → 立即提交服务器
func _push_stat(key: String, value) -> void:
	# 关键防御：先按后台 Max 钳制，绝不允许把越界值发给服务端
	value = _clamp_stat(key, value)
	statistics[key] = value

	if not steam_ready:
		return

	var ok: bool
	if _is_float_stat(key):
		ok = Steam.setStatFloat(key, float(value))
	else:
		ok = Steam.setStatInt(key, int(value))

	if not ok:
		push_warning("[Steam] 写入统计失败: %s（检查后台是否已 Publish、类型是否匹配）" % key)
		return

	store_stats()
	# 进度型成就可能刚好达标，但 GodotSteam 没有「按 stat 反查成就」的接口，
	# 所以这里不做逐条查询；在结算/存档点调一次 refresh_achievements() 即可。


## 提交。Steam 官方建议这个调用按「分钟」级频率，不要放在每帧逻辑里。
func store_stats() -> bool:
	if not steam_ready:
		return false
	var ok: bool = Steam.storeStats()
	if not ok:
		push_warning("[Steam] storeStats 失败（可能统计被设为 Increment Only 且值变小了）")
	return ok


# ---------------------------------------------------------------------------
# 6. 调试工具
# ---------------------------------------------------------------------------
## 重置本账号的全部统计与成就（上线前记得用开关屏蔽掉）
func reset_all(include_achievements: bool = true) -> void:
	if not steam_ready:
		return
	Steam.resetAllStats(include_achievements)
	for key in achievements.keys():
		achievements[key] = false
	for key in statistics.keys():
		statistics[key] = 0.0 if _is_float_stat(key) else 0
	print("[Steam] 已重置全部统计与成就")


func clear_achievement(key: String) -> void:
	if not steam_ready:
		return
	if Steam.clearAchievement(key):
		achievements[key] = false


## 打印后台所有成就的 API 名称，方便核对拼写
func dump_remote_achievements() -> void:
	for i in Steam.getNumAchievements():
		print("[Steam] 后台成就 #%d: %s" % [i, Steam.getAchievementName(i)])


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------
func _is_float_stat(key: String) -> bool:
	return FLOAT_STATS.has(key)


func _clamp_stat(key: String, value):
	if not STAT_MAX.has(key):
		return value
	var max_value = STAT_MAX[key]
	if _is_float_stat(key):
		return clampf(float(value), 0.0, float(max_value))
	return clampi(int(value), 0, int(max_value))


func _get_steam_stat(key: String):
	if _is_float_stat(key):
		return Steam.getStatFloat(key)
	return Steam.getStatInt(key)


## 被服务端拒绝后，把本地值拉回服务端的真实值，避免本地一直在错误基数上继续累加
func _resync_stats_from_steam() -> void:
	push_warning("[Steam] 服务端拒绝了统计写入，正在从服务端回滚本地值……")
	for key in statistics.keys():
		statistics[key] = _get_steam_stat(key)
		print("[Steam] 回滚 %s = %s" % [key, str(statistics[key])])


func _on_user_stats_stored(game_id: int, result: int) -> void:
	if result == ERESULT_OK:
		print("[Steam] 统计已上传到服务器 (app %s)" % str(game_id))

	elif result == ERESULT_INVALID_PARAM:
		# 超 min/max、Increment Only 回退、超出 Max Change 都会走到这里
		_resync_stats_from_steam()

	else:
		push_warning("[Steam] 统计上传失败，错误码: %d" % result)
