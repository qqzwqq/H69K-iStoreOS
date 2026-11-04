-- Copyright 2024 HinLink / daocaoren
-- H69K 风扇控制页面（经典 Lua CBI，兼容 luci-compat）
--
-- 说明：
-- 1. 页面里所有可见文案直接用中文，不走 translate()，避免中文固件里冒出英文；
-- 2. “设备树 / 内核状态”一节的数据全部读自 sysfs，也就是**设备树生效后的真实值**
--    （trip 阶梯来自 cpu-thermal 的 trip_point_*，风扇档位表来自 pwm-fan 这个
--    cooling device 的 max_state），这样页面显示的就是内核眼里的配置；
-- 3. 保存后调用 /etc/init.d/hinlinkfaninit restart；守护进程本身每 tick 重读 UCI，
--    所以即使不重启也会在数秒内生效。

-- 注意：本机 LuCI 是 ucode 版，**没有 luci.fs 模块**（require 会直接报
-- "module 'luci.fs' not found"），所以这里一律不 require luci 子模块，
-- 只用 Lua 标准库（io / os）读 sysfs，避免再踩运行库缺失的坑。

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 整文件读回（不做 trim）
local function read_raw(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local v = f:read("*a")
	f:close()
	return v
end

-- 单值读回（去空白，空则视为没读到）
local function read(path)
	local v = read_raw(path)
	if not v then return nil end
	v = trim(v)
	if v == "" then return nil end
	return v
end

local function read_num(path)
	local v = read(path)
	return v and tonumber(v) or nil
end

-- 代替 luci.fs.glob：交给 shell 展开
local function glob(pattern)
	local out = {}
	local f = io.popen("ls -d " .. pattern .. " 2>/dev/null")
	if not f then return out end
	local line
	for line in f:lines() do
		line = trim(line)
		if line ~= "" then out[#out + 1] = line end
	end
	f:close()
	return out
end

-- 执行命令，返回是否成功（兼容 Lua 5.1 的返回 0 与 5.2+ 的返回 true）
local function run(cmd)
	local ok = os.execute(cmd)
	return ok == true or ok == 0
end

-- ============ sysfs 读取工具 ============

-- pwm-fan 的 hwmon 目录（pwm1 / pwm1_enable / name）
local function find_hwmon()
	local _, p, n
	for _, p in ipairs(glob("/sys/class/hwmon/hwmon*")) do
		n = read(p .. "/name")
		if n == "pwmfan" or n == "pwm-fan" or n == "pwm_fan" then
			return p
		end
	end
	for _, p in ipairs(glob("/sys/devices/platform/*pwm-fan*/hwmon/hwmon*")) do
		return p
	end
	return nil
end

-- CPU 温度 zone（设备树里的风扇 trip 都挂在 cpu-thermal）
local function find_temp_zone()
	local wants = { "cpu-thermal", "soc-thermal", "cpu_thermal" }
	local i, _, p
	for i = 1, #wants do
		for _, p in ipairs(glob("/sys/class/thermal/thermal_zone*")) do
			if read(p .. "/type") == wants[i] then
				return p
			end
		end
	end
	return nil
end

-- 内核视角的风扇 cooling device（设备树 cooling-levels 注册出来的）
local function find_cdev()
	local _, p, t
	for _, p in ipairs(glob("/sys/class/thermal/cooling_device*")) do
		t = read(p .. "/type")
		if t == "pwm-fan" or t == "pwmfan" then
			return p
		end
	end
	return nil
end

-- 读设备的温度阶梯（就是设备树里的 trips）
local function read_trips(zone)
	local out = {}
	local i = 0
	while true do
		local t = read_num(zone .. "/trip_point_" .. i .. "_temp")
		if not t then break end
		out[#out + 1] = {
			temp = t / 1000,
			type = read(zone .. "/trip_point_" .. i .. "_type") or "",
			hyst = (read_num(zone .. "/trip_point_" .. i .. "_hyst") or 0) / 1000,
		}
		i = i + 1
	end
	return out
end

-- 守护进程写的状态文件
local function read_state()
	local s = {}
	local f = read_raw("/var/run/hinlinkfan.state")
	if not f then return s end
	local line, k, v
	for line in f:gmatch("[^\r\n]+") do
		k, v = line:match("^([%w_]+)=(.*)$")
		if k then s[k] = v end
	end
	return s
end

-- 风扇转叶动画（随转速变化）
-- 用 SVG 内联 SMIL（<animateTransform> 的 dur 直接写在属性上），不用 CSS @keyframes：
-- 主题构建会用 csstidy 压缩 CSS，@supports/@keyframes 这类它不认识的块会被整块丢掉。
-- 返回: svg 标记, 档位文字
local function fan_svg(pwm)
	local p = tonumber(pwm or "") or 0

	if p < 0 then p = 0 end
	if p > 255 then p = 255 end

	local dur, cls, label
	if p == 0 then
		dur = nil
		cls = "hinfan-fan-stop"
		label = "停转"
	elseif p <= 80 then
		dur = string.format("%.2f", 2.20 - (p / 80) * 0.70) -- 2.20 ~ 1.50s
		cls = "hinfan-fan-slow"
		label = "低速"
	elseif p <= 160 then
		dur = string.format("%.2f", 1.50 - ((p - 80) / 80) * 0.55) -- 1.50 ~ 0.95s
		cls = "hinfan-fan-mid"
		label = "中速"
	elseif p < 255 then
		dur = string.format("%.2f", 0.95 - ((p - 160) / 95) * 0.35) -- 0.95 ~ 0.60s
		cls = "hinfan-fan-fast"
		label = "高速"
	else
		dur = "0.50"
		cls = "hinfan-fan-max"
		label = "全速"
	end

	-- 5 片叶子（同一个路径旋转 72°×n）；不要用 <use>/href，兼容性最稳
	local blades = {}
	local i
	for i = 0, 4 do
		blades[#blades + 1] = string.format(
			'<path d="M32 32C21 25 19 11 29 4C37 9 39 23 32 32Z"%s/>',
			i == 0 and "" or string.format(' transform="rotate(%d 32 32)"', i * 72))
	end

	local anim = ""
	if dur then
		anim = string.format('<animateTransform attributeName="transform" attributeType="XML"' ..
			' type="rotate" from="0 32 32" to="360 32 32" dur="%ss" repeatCount="indefinite"/>', dur)
	end

	local svg = string.format(
		'<span class="hinfan-fanwrap %s" title="%s">' ..
		'<svg viewBox="0 0 64 64" width="36" height="36" aria-hidden="true">' ..
		'<circle class="hinfan-fan-ring" cx="32" cy="32" r="29"/>' ..
		'<g class="hinfan-fan-blades">%s%s</g>' ..
		'<circle class="hinfan-fan-hub" cx="32" cy="32" r="5.5"/>' ..
		'</svg></span>',
		cls, label, table.concat(blades), anim)

	return svg, label
end

-- 守护进程是否活着：优先看状态文件新鲜度（不依赖 pgrep），其次看进程
local function daemon_running(st)
	local upd = st and tonumber(st.upd or "")
	if upd and os.time() - upd <= 15 then
		return true, "状态文件新鲜"
	end
	if run("pgrep -f hinlinkfan-daemon >/dev/null 2>&1") then
		return true, "进程在运行"
	end
	return false, "进程未运行"
end

-- ============ 状态卡片（HTML 注入到页面描述区） ============

local MODE_INFO = {
	kernel = { label = "内核温控", cls = "ok", note = "设备树 cooling-maps 自动调速" },
	manual = { label = "自定义曲线", cls = "info", note = "用户态守护进程接管 pwm1" },
	off = { label = "强制停转", cls = "bad", note = "已放弃风扇散热保护" },
	full = { label = "全速", cls = "warn", note = "风扇 100% 运转" },
}

local ENABLE_TEXT = {
	["0"] = "不控速（PWM 输出关闭）",
	["1"] = "手动（写 pwm1 生效）",
	["2"] = "自动（设备树温控接管）",
}

local function temp_class(t)
	if not t then return "" end
	if t >= 75 then return "hot" end
	if t >= 60 then return "warn" end
	if t >= 45 then return "info" end
	return "ok"
end

local function status_card()
	local hw = find_hwmon()
	local zone = find_temp_zone()
	local cdev = find_cdev()
	local st = read_state()

	local temp = zone and read_num(zone .. "/temp")
	temp = temp and temp / 1000 or nil

	local pwm = hw and read_num(hw .. "/pwm1")
	local en = hw and read(hw .. "/pwm1_enable")
	local cur = cdev and read(cdev .. "/cur_state")
	local maxs = cdev and read(cdev .. "/max_state")

	local mode = st.mode or "kernel"
	local mi = MODE_INFO[mode] or MODE_INFO.kernel

	local run, why = daemon_running(st)

	local pwm_pct = pwm and math.floor(pwm / 2.55 + 0.5) or 0

	local h = {}
	h[#h + 1] = '<div class="hinfan-card">'

	-- 模式徽章
	h[#h + 1] = string.format(
		'<div class="hinfan-hero hinfan-%s">' ..
		'<div class="hinfan-hero-main"><span class="hinfan-badge">%s</span>' ..
		'<span class="hinfan-hero-note">%s</span></div>' ..
		'<div class="hinfan-hero-sub">控制权 pwm1_enable=%s · %s</div></div>',
		mi.cls, mi.label, mi.note, en or "?", ENABLE_TEXT[en or ""] or "未知")

	-- 温度 + 转速 两块数据
	h[#h + 1] = '<div class="hinfan-grid">'

	h[#h + 1] = string.format(
		'<div class="hinfan-tile hinfan-temp-tile"><div class="hinfan-temp-info"><div class="hinfan-tile-k">CPU 温度</div>' ..
		'<div class="hinfan-tile-v hinfan-t-%s">%s<span class="hinfan-unit">°C</span></div>' ..
		'<div class="hinfan-tile-s">%s</div></div>',
		temp_class(temp),
		temp and string.format("%.1f", temp) or "--",
		zone and zone:gsub("^/sys/class/thermal/", "") or "未找到 thermal zone")

	-- 独立温度→PWM曲线区域：不再挤在 CPU 温度卡片内，手机端也能完整阅读。
	local current_curve_html = ""
	local ok_uci, uci = pcall(require, "luci.model.uci")
	local curve_points, curve_label = {}, "当前自定义曲线"
	if ok_uci and uci then
		local c = uci.cursor()
		local preset = c:get("hinlinkfan", "global", "preset_applied")
		if preset and preset ~= "" and preset ~= "custom" and preset ~= "keep" then curve_label = "当前曲线（预设：" .. preset .. "）" end
		c:foreach("hinlinkfan", "global", function(sec)
			local values = sec.curve or {}
			for _, v in ipairs(values) do
				local t, pwm = tostring(v):match("^(%d+):(%d+)$")
				if t and pwm then curve_points[#curve_points + 1] = {tonumber(t), tonumber(pwm)} end
			end
		end)
	end
	if #curve_points > 0 then
		table.sort(curve_points, function(a,b) return a[1] < b[1] end)
		local minT, maxT = curve_points[1][1], curve_points[#curve_points][1]
		if maxT <= minT then maxT = minT + 1 end
		local x0, y0, w, hh = 36, 18, 286, 78
		local function px(t) return x0 + (t-minT)/(maxT-minT)*w end
		local function py(pwm) return y0 + hh - (pwm/255)*hh end
		local coords, labels, dots, grid = {}, {}, {}, {}
		for i=0,4 do
			local yy = y0 + hh - i*hh/4
			grid[#grid+1] = string.format('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="currentColor" stroke-opacity=".18" stroke-dasharray="3 3"/><text x="29" y="%.1f" text-anchor="end" fill="currentColor" fill-opacity=".72" font-size="9">%d</text>', x0, yy, x0+w, yy, yy+3, math.floor(i*255/4))
		end
		for i, pt in ipairs(curve_points) do
			local x, y = px(pt[1]), py(pt[2])
			coords[#coords+1] = string.format('%.1f,%.1f', x, y)
			dots[#dots+1] = string.format('<circle cx="%.1f" cy="%.1f" r="4" fill="#4b8dff" stroke="#ffffff" stroke-width="1.2"/>', x, y)
			local labelY = y + (i % 2 == 1 and -8 or 15)
			if labelY < 12 then labelY = y + 14 end
			if labelY > 103 then labelY = y - 8 end
			local anchor = i == 1 and 'start' or (i == #curve_points and 'end' or 'middle')
			local labelX = x
			if i == 1 then labelX = x + 2 elseif i == #curve_points then labelX = x - 2 end
			labels[#labels+1] = string.format('<text x="%.1f" y="%.1f" text-anchor="%s" fill="currentColor" font-size="10" font-weight="700">%d°C · %d</text>', labelX, labelY, anchor, pt[1], pt[2])
		end
		current_curve_html = '<div class="hinfan-curve-current"><svg viewBox="0 0 350 132" role="img" aria-label="当前温度转PWM曲线"><text x="8" y="12" fill="currentColor" fill-opacity=".72" font-size="9">PWM</text>' .. table.concat(grid) .. '<polyline points="' .. table.concat(coords, ' ') .. '" fill="none" stroke="#4b8dff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>' .. table.concat(dots) .. table.concat(labels) .. '<text x="179" y="121" text-anchor="middle" fill="currentColor" fill-opacity=".72" font-size="10">温度 (°C)</text></svg><div class="hinfan-curve-caption">蓝线为当前保存曲线 · 节点显示温度/PWM</div></div>'
	end

	local fan, fan_label = fan_svg(pwm)

	h[#h + 1] = string.format(
		'<div class="hinfan-tile"><div class="hinfan-tile-k">风扇转速</div>' ..
		'<div class="hinfan-tile-v">%s<span class="hinfan-unit">/255</span>%s</div>' ..
		'<div class="hinfan-bar"><span style="width:%d%%"></span></div>' ..
		'<div class="hinfan-tile-s">%s · 占空比约 %d%%</div></div>',
		pwm or "--", fan, pwm_pct, fan_label, pwm_pct)

	-- 将设备树实时信息并入顶部内核档位卡片。
	local kernel_details = {}
	kernel_details[#kernel_details + 1] = '<div class="hinfan-kernel-intro">以下为 sysfs 实时读取的只读信息，用于核对驱动、温度传感器和内核温控档位。</div>'
	kernel_details[#kernel_details + 1] = string.format('<div class="hinfan-kv"><b>风扇驱动节点</b><span>%s</span></div>', hw or "未找到 pwm-fan hwmon")
	kernel_details[#kernel_details + 1] = string.format('<div class="hinfan-kv"><b>内核 cooling device</b><span>%s（type=%s，当前档位 %s/%s）</span></div>', cdev and cdev:gsub("^/sys/class/thermal/", "") or "未注册", cdev and (read(cdev .. "/type") or "?") or "?", cur or "?", maxs or "?")
	kernel_details[#kernel_details + 1] = string.format('<div class="hinfan-kv"><b>温度传感器</b><span>%s</span></div>', zone or "未找到 cpu-thermal")
	for detail_i, detail_tp in ipairs(zone and read_trips(zone) or {}) do
		kernel_details[#kernel_details + 1] = string.format('<div class="hinfan-kv"><b>温度阶梯 #%d</b><span>%.0f°C　类型 %s　回差 %.0f°C</span></div>', detail_i, detail_tp.temp, detail_tp.type, detail_tp.hyst)
	end
	local detail_st = read_state()
	local detail_report = detail_st.mode and string.format("模式 %s　温度 %s°C　PWM %s（目标 %s）　档位 %s", detail_st.mode, detail_st.temp or "--", detail_st.pwm or "--", detail_st.target or "--", detail_st.level or "--") or "暂无状态文件（守护进程未运行）"
	kernel_details[#kernel_details + 1] = string.format('<div class="hinfan-kv"><b>守护进程上报</b><span>%s</span></div>', detail_report)
	h[#h + 1] = string.format(
		'<div class="hinfan-tile hinfan-kernel-tile"><div class="hinfan-tile-k">内核档位</div>' ..
		'<div class="hinfan-tile-v">%s<span class="hinfan-unit">/%s</span></div>' ..
		'<div class="hinfan-tile-s">%s</div></div>',
		cur or "--", maxs or "--",
		cdev and "档位表来自设备树 cooling-levels" or "未注册 cooling device")


	h[#h + 1] = string.format(
		'<div class="hinfan-tile"><div class="hinfan-tile-k">守护进程</div>' ..
		'<div class="hinfan-tile-v hinfan-t-%s">%s</div>' ..
		'<div class="hinfan-tile-s">%s</div></div>',
		run and "ok" or "bad", run and "运行中" or "未运行",
		string.format("%s · %s", why or "", st.upd and os.date("%H:%M:%S", tonumber(st.upd)) or "--"))

	h[#h + 1] = "</div>" -- hinfan-grid

	-- 经典布局：内核设备树温控说明作为独立栏位，设备树与内核状态另设折叠栏。
	h[#h + 1] = string.format('<div class="hinfan-kernel-strip">内核设备树温控（档位 %s/%s）</div>', cur or "--", maxs or "--")
	h[#h + 1] = '<details class="hinfan-kernel-details"><summary>展开设备树与内核状态</summary><div class="hinfan-kernel-content">' .. table.concat(kernel_details) .. '</div></details>'
	h[#h + 1] = '<div class="hinfan-help"><b>两层温控，互不打架：</b>默认由<b>内核</b>按设备树里的 <code>cooling-maps</code> 调速（45/55/65/75°C 四档）；选择<b>自定义曲线</b>后由用户态守护进程接管风扇，关闭时会自动把控制权交还内核。</div>'


	if st.note and st.note ~= "" then
		h[#h + 1] = string.format('<div class="hinfan-note">%s</div>', st.note)
	end

	h[#h + 1] = "</div>"

	return table.concat(h)
end

-- ============ 页面 ============

local m = Map("hinlinkfan", "调温大师", status_card())

-- 独立样式：不依赖第三方前端库，兼容 LuCI 经典 CBI 页面与暗色主题。
m.description = [[
<style>
.hinfan-card{margin:0 0 20px;color:var(--content-color,#202938)}
.hinfan-hero{box-sizing:border-box;border-radius:14px;padding:18px 20px;margin:0 0 16px;background:linear-gradient(120deg,#20b985,#43d7a0);color:#fff;box-shadow:0 7px 22px rgba(20,180,125,.17)}
.hinfan-hero.bad{background:linear-gradient(120deg,#b83246,#e65353)}.hinfan-hero.warn{background:linear-gradient(120deg,#bb791d,#e5a43d)}.hinfan-hero.info{background:linear-gradient(120deg,#2766bb,#498ce2)}
.hinfan-hero-main{display:flex;align-items:center;flex-wrap:wrap;gap:10px;font-size:15px;font-weight:700}.hinfan-badge{font-size:16px}.hinfan-hero-note{font-weight:500;opacity:.96}.hinfan-hero-sub{font-size:12px;margin-top:8px;opacity:.95}
.hinfan-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:9px;margin:0 0 14px}
.hinfan-tile{min-width:0;box-sizing:border-box;border:1px solid var(--border-color,#d1d5db);border-radius:12px;padding:12px;background:var(--secondary-bg,#ffffff);box-shadow:0 4px 14px rgba(0,0,0,.09);transition:border-color .18s ease,transform .18s ease}.hinfan-tile:hover{border-color:rgba(102,120,255,.55);transform:translateY(-1px)}
.hinfan-tile-k{font-size:12px;color:var(--secondary-text-color,#4b5563);margin-bottom:6px}.hinfan-tile-v{font-size:24px;font-weight:750;line-height:1.25;overflow-wrap:anywhere}.hinfan-unit{font-size:12px;font-weight:600;margin-left:4px;color:var(--secondary-text-color,#4b5563)}.hinfan-tile-s{font-size:11px;color:var(--secondary-text-color,#4b5563);margin-top:7px;overflow-wrap:anywhere}
.hinfan-t-ok{color:#39cf9a}.hinfan-t-info{color:#5ba3f5}.hinfan-t-warn{color:#f1b64f}.hinfan-t-hot,.hinfan-t-bad{color:#f06464}
.hinfan-bar{height:6px;background:var(--border-color,#444);border-radius:99px;overflow:hidden;margin-top:9px}.hinfan-bar span{display:block;height:100%;border-radius:99px;background:linear-gradient(90deg,#32c995,#8ce6bb);transition:width .35s ease}
.hinfan-fanwrap{display:inline-flex;vertical-align:middle;margin-left:8px;color:#36c995}.hinfan-fanwrap svg{display:block}.hinfan-fan-ring{fill:none;stroke:currentColor;stroke-opacity:.24;stroke-width:2}.hinfan-fan-blades{fill:currentColor}.hinfan-fan-hub{fill:currentColor}.hinfan-fan-stop{color:#9299a3}.hinfan-fan-slow{color:#60cfa5}.hinfan-fan-mid{color:#35c995}.hinfan-fan-fast{color:#f1b64f}.hinfan-fan-max{color:#f06464}
.hinfan-curve-empty{padding:22px 16px;border:1px dashed var(--border-color,#9aa8ba);border-radius:10px;text-align:center;color:var(--secondary-text-color,#52657d);font-size:13px;line-height:1.8;background:rgba(128,128,128,.045)}
.hinfan-curve-current{box-sizing:border-box;width:100%;max-width:1080px;margin:10px auto 14px;padding:14px 16px;border:1px solid var(--border-color,#454545);border-radius:10px;background:rgba(128,128,128,.06)}.hinfan-curve-title{font-weight:700;margin-bottom:8px}.hinfan-curve-current svg{display:block;width:100%;max-width:760px;height:auto;min-height:150px;margin:0 auto}.hinfan-curve-caption{font-size:11px;opacity:.72;text-align:center}
.hinfan-note,.hinfan-help{border-radius:9px;padding:12px 14px;margin:0 0 14px;background:var(--secondary-bg,#f3f6fa);border-left:3px solid #4c72e8;line-height:1.75;font-size:12px}.hinfan-help code{font-size:11px}
/* 保留 LuCI 原有页面与卡片边框宽度，只将表单内容区居中 */
.cbi-map{width:100%!important;max-width:none!important;box-sizing:border-box!important;margin-left:0!important;margin-right:0!important}
.cbi-section .cbi-value{max-width:1080px!important;margin-left:auto!important;margin-right:auto!important}
.cbi-section .cbi-section-descr{max-width:1080px;margin-left:auto;margin-right:auto}
@media(max-width:767px){.cbi-section .cbi-value{max-width:100%!important}}
/* 表单统一单列纵向：字段标题在上、控件在下，内容区域居中；保留外层原边框宽度 */
.cbi-section .cbi-value{display:flex!important;flex-direction:column!important;align-items:center!important;max-width:none!important;width:100%!important;margin:0 auto!important;padding:14px 0!important;gap:7px!important}
.cbi-section .cbi-value-title{display:block!important;float:none!important;width:100%!important;max-width:760px!important;text-align:center!important;margin:0 auto!important;padding:0!important}
.cbi-section .cbi-value-field{display:block!important;float:none!important;width:100%!important;max-width:760px!important;margin:0 auto!important;text-align:left!important}
.cbi-section .cbi-value-description{max-width:760px!important;margin:6px auto 0!important;text-align:center!important}
.cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-section .cbi-value-field select,.cbi-section .cbi-value-field textarea{width:100%;max-width:100%!important;box-sizing:border-box!important}
.cbi-section .cbi-value-field ul{width:100%!important}
/* 下半部分表单卡片与选项布局 */
.cbi-section{box-sizing:border-box;border:1px solid var(--border-color,#343434)!important;border-radius:14px!important;overflow:hidden;margin:0 0 18px!important;padding:0 20px 18px!important;background:var(--content-bg,#ffffff);box-shadow:0 4px 14px rgba(0,0,0,.07)}
.cbi-section>legend{display:block;box-sizing:border-box;width:calc(100% + 40px);margin:0 -20px 12px!important;padding:13px 18px!important;background:linear-gradient(100deg,var(--secondary-bg,#f3f6fa),var(--content-bg,#ffffff));border-left:3px solid #6678ff;font-size:16px;font-weight:750;line-height:1.5;color:var(--content-color,#202938)}
.cbi-section .cbi-section-descr{line-height:1.7;color:var(--secondary-text-color,#4b5563);font-size:12px;margin:8px 0 14px}
.cbi-value{padding:10px 0!important;border:0!important;min-height:34px;border-bottom:1px solid rgba(128,128,128,.10)!important}.cbi-value:last-child{border-bottom:0!important}
.cbi-value-title{font-weight:650;line-height:1.65;padding-top:3px;color:var(--content-color,#202938)}
.cbi-value-field{min-width:0}
.cbi-value-description{line-height:1.7;color:var(--secondary-text-color,#4b5563);font-size:12px;margin-top:6px;max-width:900px}
/* 单选/复选项：控件与文字同行，窄屏允许文字自然换行 */
.cbi-value-field ul{display:flex!important;flex-direction:column!important;align-items:stretch!important;gap:8px!important;margin:0!important;padding:0!important;list-style:none!important}
.cbi-value-field ul li{display:block!important;line-height:1.6!important;margin:0!important;padding:8px 10px!important;min-height:24px;box-sizing:border-box}
.cbi-value-field .cbi-input-radio{display:block!important;margin:0!important;padding:0!important}
.cbi-value-field .cbi-input-radio label,.cbi-value-field ul label,.cbi-value-field label:has(input[type="radio"]){display:inline!important;line-height:1.6!important;margin:0!important;white-space:normal!important;cursor:pointer}
.cbi-value-field input[type=radio],.cbi-value-field input[type=checkbox]{display:inline-block!important;vertical-align:middle!important;margin:2px 8px 0 0!important;accent-color:#6678ff}
.cbi-value-field label{line-height:1.65;cursor:pointer}
/* 表单控件统一风格：清晰边框、柔和聚焦态 */
.cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-value-field select,.cbi-value-field textarea{box-sizing:border-box;max-width:100%;border:1px solid var(--border-color,#cbd5e1)!important;border-radius:8px!important;background:var(--input-bg,var(--content-bg,#ffffff))!important;color:var(--content-color,#202938)!important;padding:9px 11px!important;min-height:38px;box-shadow:none!important;transition:border-color .15s ease,box-shadow .15s ease}
.cbi-value-field input:not([type=radio]):not([type=checkbox]):focus,.cbi-value-field select:focus,.cbi-value-field textarea:focus{border-color:#6678ff!important;box-shadow:0 0 0 3px rgba(102,120,255,.14)!important;outline:none!important}
.cbi-value-field input[type=radio],.cbi-value-field input[type=checkbox]{width:15px;height:15px;accent-color:#6678ff}
.cbi-value-field .cbi-button{border-radius:8px;min-height:36px}
.cbi-value-field ul li,.cbi-value-field label:has(input[type=radio]){padding:7px 10px!important;border:1px solid rgba(128,128,128,.16);border-radius:8px;background:rgba(128,128,128,.035);min-width:0;transition:background .15s ease,border-color .15s ease}
.cbi-value-field ul li:hover,.cbi-value-field label:has(input[type=radio]):hover{border-color:rgba(102,120,255,.5);background:rgba(102,120,255,.07)}
.cbi-value-field ul li label{padding:0!important;border:0!important;background:transparent!important;min-width:0!important;display:inline!important}
@media(max-width:767px){.cbi-section{padding:0 12px 12px!important}.cbi-section>legend{width:calc(100% + 24px);margin-left:-12px!important;margin-right:-12px!important;padding:12px!important}.cbi-value{display:block!important;padding:9px 0!important}.cbi-value-title{display:block;width:auto!important;margin-bottom:7px}.cbi-value-field{display:block;width:100%!important}.cbi-value-field ul{gap:8px!important}.cbi-value-field ul li,.cbi-value-field label:has(input[type=radio]){min-width:0;width:100%;box-sizing:border-box}}

@media(max-width:900px){.hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.hinfan-tile-v{font-size:24px}}
@media(max-width:480px){.hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.hinfan-tile{padding:10px;border-radius:10px}.hinfan-tile-v{font-size:21px}.hinfan-hero{padding:14px;border-radius:11px}.hinfan-hero-main{align-items:flex-start}.cbi-section{border-radius:11px!important}}

/* CPU 卡片左右分栏：温度数值固定在左侧，曲线放在右侧 */
.hinfan-temp-tile{display:block}
.hinfan-temp-info{min-width:0}

.hinfan-help,.cbi-section .cbi-section-descr{color:inherit!important;opacity:.88}.hinfan-help{background:rgba(128,128,128,.10)!important;border:1px solid rgba(128,128,128,.24)!important;border-left:3px solid #4c72e8!important}.cbi-section{background:rgba(128,128,128,.07)!important;color:inherit!important}.cbi-section>legend{background:rgba(128,128,128,.13)!important;color:inherit!important}.cbi-value-title,.cbi-value-description{color:inherit!important}.cbi-value-description{opacity:.78}
.hf-chart-wrap{width:100%;overflow:hidden;margin-top:10px}.hf-chart{display:block;width:100%;max-width:300px;height:auto;min-height:75px}.hf-chart-grid{stroke:var(--border-color,#d1d5db);stroke-dasharray:3 4;stroke-width:1}.hf-chart-axis{fill:var(--secondary-text-color,#4b5563);font-size:10px}.hf-chart-label{fill:var(--content-color,#202938);font-size:10px;font-weight:700}.hf-chart-current{stroke:#f97316;stroke-width:1.5;stroke-dasharray:4 3}
/* 主题变量在部分 Argon/iStoreOS 暗色主题下并非标准变量，显式兼容暗色标记 */
html[data-darkmode="true"] .hinfan-card,html.dark .hinfan-card,body.dark .hinfan-card{color:#e5e7eb}
html[data-darkmode="true"] .hinfan-tile,html.dark .hinfan-tile,body.dark .hinfan-tile{background:#242424;color:#e5e7eb;border-color:#50545b}
html[data-darkmode="true"] .hinfan-tile-k,html.dark .hinfan-tile-k,body.dark .hinfan-tile-k,html[data-darkmode="true"] .hinfan-tile-s,html.dark .hinfan-tile-s,body.dark .hinfan-tile-s{color:#b8c0cc}
html[data-darkmode="true"] .cbi-section,html.dark .cbi-section,body.dark .cbi-section{background:#202124!important;color:#e5e7eb}
html[data-darkmode="true"] .cbi-section>legend,html.dark .cbi-section>legend,body.dark .cbi-section>legend{background:#303236;color:#f3f4f6}
html[data-darkmode="true"] .cbi-value-title,html.dark .cbi-value-title,body.dark .cbi-value-title{color:#e5e7eb}
html[data-darkmode="true"] .cbi-value-description,html.dark .cbi-value-description,body.dark .cbi-value-description{color:#b8c0cc}
html[data-darkmode="true"] .cbi-value-field input:not([type=radio]):not([type=checkbox]),html.dark .cbi-value-field input:not([type=radio]):not([type=checkbox]),body.dark .cbi-value-field input:not([type=radio]):not([type=checkbox]),html[data-darkmode="true"] .cbi-value-field select,html.dark .cbi-value-field select,body.dark .cbi-value-field select,html[data-darkmode="true"] .cbi-value-field textarea,html.dark .cbi-value-field textarea,body.dark .cbi-value-field textarea{color:#f3f4f6!important;background:#292b30!important;border-color:#555a63!important}



/* 标题栏端点修正：不再使用负外边距和超宽计算，避免左右两端溢出/露出底色 */
.cbi-section>legend{
  display:block!important;box-sizing:border-box!important;width:auto!important;
  margin:0 0 12px!important;padding:13px 18px!important;
  border-radius:9px!important;border-left:3px solid #6678ff!important;
  background:#f8fafc!important;color:#202938!important;
  overflow-wrap:anywhere;
}
.cbi-section{padding:12px 18px 18px!important}
html[data-darkmode="true"] .cbi-section>legend,
html.dark .cbi-section>legend,body.dark .cbi-section>legend{
  background:#303236!important;color:#f3f4f6!important;border-left-color:#8290ff!important;
}
html[data-darkmode="true"] .cbi-section,
html.dark .cbi-section,body.dark .cbi-section{padding:12px 18px 18px!important}
@media(max-width:767px){
  .cbi-section{padding:10px 12px 12px!important}
  .cbi-section>legend{width:auto!important;margin:0 0 12px!important;padding:12px!important;border-radius:8px!important}
}


/* 动态曲线输入行统一宽度；暗色主题下新增输入框也使用柔和深灰，不刺眼 */
.cbi-value-field .cbi-dynlist{width:100%!important;max-width:100%!important;box-sizing:border-box!important}
.cbi-value-field .cbi-dynlist .item,.cbi-value-field .cbi-dynlist>div{max-width:100%;box-sizing:border-box}
.cbi-value-field .cbi-dynlist input:not([type=radio]):not([type=checkbox]){box-sizing:border-box!important;max-width:calc(100% - 38px)!important;width:calc(100% - 38px)!important}
html[data-darkmode="true"] .cbi-value-field input:not([type=radio]):not([type=checkbox]),html.dark .cbi-value-field input:not([type=radio]):not([type=checkbox]),body.dark .cbi-value-field input:not([type=radio]):not([type=checkbox]),html[data-darkmode="true"] .cbi-value-field select,html.dark .cbi-value-field select,body.dark .cbi-value-field select,html[data-darkmode="true"] .cbi-value-field textarea,html.dark .cbi-value-field textarea,body.dark .cbi-value-field textarea{background:#292b30!important;color:#d8dde6!important;border-color:#50545b!important}

/* 1.3-17：恢复顶部四张状态卡片的紧凑尺寸，并缩短温度→PWM动态列表输入框 */
.hinfan-grid{grid-template-columns:repeat(4,minmax(0,1fr))!important;gap:8px!important;margin-bottom:10px!important}
.hinfan-tile{padding:9px 10px!important;border-radius:10px!important;box-shadow:0 2px 8px rgba(0,0,0,.07)!important}
.hinfan-tile-k{font-size:11px!important;margin-bottom:4px!important;line-height:1.4!important}
.hinfan-tile-v{font-size:20px!important;line-height:1.2!important}
.hinfan-unit{font-size:11px!important}
.hinfan-tile-s{font-size:10px!important;margin-top:5px!important;line-height:1.45!important}
@media(max-width:900px){.hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important}.hinfan-tile-v{font-size:20px!important}}
@media(max-width:480px){.hinfan-grid{gap:7px!important}.hinfan-tile{padding:8px!important}.hinfan-tile-v{font-size:18px!important}}
/* 动态曲线每一行不再横向铺满整个表单，保持与 1.3-10 类似的紧凑宽度 */
.cbi-section .cbi-value:has(.cbi-dynlist) .cbi-value-field{width:100%!important;max-width:460px!important;align-self:center!important}
.cbi-section .cbi-value:has(.cbi-dynlist) .cbi-value-title{max-width:460px!important}
.cbi-value-field .cbi-dynlist{width:100%!important;max-width:460px!important}
.cbi-value-field .cbi-dynlist input:not([type=radio]):not([type=checkbox]){width:calc(100% - 38px)!important;max-width:calc(100% - 38px)!important}
@media(max-width:600px){.cbi-section .cbi-value:has(.cbi-dynlist) .cbi-value-field,.cbi-value-field .cbi-dynlist{max-width:100%!important}}

/* 1.3-16：CPU 温度数值在左，当前蓝色温度→PWM曲线在右；保持外卡片宽度 */
.hinfan-temp-tile{display:grid!important;grid-template-columns:minmax(105px,.72fr) minmax(0,2fr)!important;align-items:center!important;gap:14px!important;}
.hinfan-temp-info{min-width:0!important;align-self:center!important;}
.hinfan-temp-tile .hinfan-curve-current{width:100%!important;max-width:none!important;min-width:0!important;margin:0!important;padding:10px 12px!important;box-sizing:border-box!important;}
.hinfan-temp-tile .hinfan-curve-current svg{width:100%!important;max-width:none!important;min-height:0!important;height:auto!important;}
.hinfan-temp-tile .hinfan-curve-title{font-size:12px!important;margin-bottom:4px!important;}
.hinfan-temp-tile .hinfan-curve-caption{font-size:10px!important;margin-top:2px!important;}
@media(max-width:480px){.hinfan-temp-tile{grid-template-columns:minmax(82px,.65fr) minmax(0,2fr)!important;gap:8px!important;padding:10px!important}.hinfan-temp-tile .hinfan-curve-current{padding:7px!important}.hinfan-temp-tile .hinfan-curve-title{font-size:11px!important}.hinfan-temp-tile .hinfan-curve-caption{font-size:9px!important}}
/* 1.3-18：状态卡片进一步紧凑；去掉曲线外框；三个参数输入框缩短并采用柔和深灰 */
.hinfan-grid{gap:6px!important;margin-bottom:8px!important}
.hinfan-tile{padding:6px 8px!important;border-radius:8px!important;box-shadow:none!important}
.hinfan-tile-k{font-size:10px!important;margin-bottom:3px!important}
.hinfan-tile-v{font-size:17px!important;line-height:1.15!important}
.hinfan-unit{font-size:10px!important}
.hinfan-tile-s{font-size:9px!important;margin-top:3px!important;line-height:1.35!important}
@media(max-width:480px){.hinfan-tile{padding:6px!important}.hinfan-tile-v{font-size:16px!important}}
/* PWM 曲线保留蓝线、坐标与数值，但去掉包围曲线的黑色边框/底框 */
.hinfan-temp-tile .hinfan-curve-current{border:0!important;background:transparent!important;box-shadow:none!important;padding:4px 6px!important;border-radius:0!important}
/* 采样周期、降档回差、降温步长与上方选项区域统一紧凑宽度 */
.cbi-section .cbi-value:has(input[id$=".tick"]) .cbi-value-field,
.cbi-section .cbi-value:has(input[id$=".hysteresis"]) .cbi-value-field,
.cbi-section .cbi-value:has(input[id$=".ramp"]) .cbi-value-field{width:100%!important;max-width:460px!important;align-self:center!important}
.cbi-section .cbi-value:has(input[id$=".tick"]) .cbi-value-title,
.cbi-section .cbi-value:has(input[id$=".hysteresis"]) .cbi-value-title,
.cbi-section .cbi-value:has(input[id$=".ramp"]) .cbi-value-title{max-width:460px!important}
/* 输入框统一柔和灰色，避免亮白块 */
.cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-value-field select,.cbi-value-field textarea{background:#292b30!important;color:#d8dde6!important;border-color:#50545b!important}
/* 1.3-22：选项控件进一步缩小，并与标题区域统一宽度 */
.cbi-section .cbi-value{padding:4px 0!important;gap:2px!important;min-height:0!important}
.cbi-section .cbi-value-title{line-height:1.25!important;padding-top:0!important;margin-bottom:0!important;font-size:11px!important}
.cbi-section .cbi-value-field{line-height:1.3!important}
.cbi-section .cbi-value-description{line-height:1.3!important;margin-top:2px!important;font-size:10px!important}
.cbi-section .cbi-section-descr{line-height:1.35!important;margin:3px 0 5px!important}
.cbi-section .cbi-value-field ul{gap:3px!important}
.cbi-section .cbi-value-field ul li{min-height:0!important;padding:3px 6px!important;line-height:1.25!important;font-size:11px!important}
.cbi-section .cbi-value-field label:has(input[type=radio]),.cbi-section .cbi-value-field label:has(input[type=checkbox]){padding:3px 6px!important;font-size:11px!important;line-height:1.25!important;min-height:0!important}
.cbi-section .cbi-value-field input[type=radio],.cbi-section .cbi-value-field input[type=checkbox]{transform:scale(.88);margin-right:3px!important}
.cbi-section .cbi-value:has(input[type=radio]) .cbi-value-field,.cbi-section .cbi-value:has(input[type=checkbox]) .cbi-value-field{width:100%!important;max-width:460px!important;margin-left:auto!important;margin-right:auto!important;box-sizing:border-box!important}
.cbi-section .cbi-value:has(input[type=radio]) .cbi-value-title,.cbi-section .cbi-value:has(input[type=checkbox]) .cbi-value-title{max-width:460px!important;margin-left:auto!important;margin-right:auto!important}
/* 1.3-24：进一步放大顶部四个状态卡片标题 */
.hinfan-tile-k{font-size:15px!important;line-height:1.3!important;margin-bottom:4px!important}
@media(max-width:900px){.hinfan-tile-k{font-size:14px!important}}
/* 1.3-25：上方设置项与下方设备树只读状态统一内容宽度并对齐 */
.cbi-section .cbi-value-title,
.cbi-section .cbi-value-field,
.cbi-section .cbi-value-description {
  box-sizing: border-box !important;
  width: 100% !important;
  max-width: 460px !important;
  margin-left: auto !important;
  margin-right: auto !important;
}
.cbi-section .cbi-value-field { text-align: left !important; }
.cbi-section .cbi-value-title { text-align: center !important; }

/* 1.4.2：重新组织信息层级。状态仪表盘、曲线、控制表单各自独立。 */
.hinfan-card{display:block;width:100%;max-width:1180px;margin:0 auto 22px;box-sizing:border-box}
.hinfan-hero{padding:18px 22px;border-radius:16px;margin-bottom:14px}
.hinfan-hero-main{gap:12px;align-items:center}
.hinfan-badge{font-size:18px;letter-spacing:.02em}
.hinfan-hero-note{font-size:13px}
.hinfan-hero-sub{font-size:12px;line-height:1.6;overflow-wrap:anywhere}
.hinfan-grid{display:grid!important;grid-template-columns:repeat(4,minmax(0,1fr))!important;gap:12px!important;margin:0!important}
.hinfan-tile{min-width:0;padding:16px!important;border-radius:14px!important;background:var(--card-bg,var(--secondary-bg,#fff))!important;box-shadow:0 3px 12px rgba(20,35,60,.07)!important}
.hinfan-tile-k{font-size:13px!important;font-weight:650;letter-spacing:.02em;margin-bottom:9px!important}
.hinfan-tile-v{font-size:clamp(22px,2.4vw,30px)!important;line-height:1.2!important;font-variant-numeric:tabular-nums}
.hinfan-tile-s{font-size:12px!important;line-height:1.55!important;margin-top:8px!important}
.hinfan-temp-tile{display:block!important}
.hinfan-temp-info{display:block!important}
.hinfan-curve-panel{box-sizing:border-box;width:100%;margin:14px 0 0;padding:16px 18px;border:1px solid var(--border-color,#d8dee8);border-radius:14px;background:var(--secondary-bg,rgba(128,128,128,.045))}
.hinfan-panel-heading{display:flex;align-items:baseline;justify-content:space-between;gap:10px;margin-bottom:8px;font-weight:750;font-size:15px}
.hinfan-panel-heading small{font-size:11px;font-weight:400;opacity:.7}
.hinfan-curve-current{width:100%!important;max-width:100%!important;margin:0!important;padding:8px 0!important;border:0!important;background:transparent!important}
.hinfan-curve-current svg{display:block;width:100%!important;max-width:900px!important;height:auto!important;min-height:0!important;margin:0 auto}
.hinfan-curve-caption{font-size:11px;margin-top:5px}
.cbi-map{max-width:1180px!important;margin-left:auto!important;margin-right:auto!important}
.cbi-section{margin:0 0 18px!important;padding:16px 20px 20px!important;border-radius:14px!important;overflow:visible!important}
.cbi-section>legend{font-size:16px!important;font-weight:750!important;padding:10px 12px!important;margin-bottom:8px!important}
.cbi-section .cbi-section-descr{max-width:820px!important;margin:4px auto 14px!important;text-align:center;line-height:1.65!important;font-size:12px!important}
.cbi-section .cbi-value{max-width:820px!important;margin-left:auto!important;margin-right:auto!important;padding:12px 0!important;gap:6px!important}
.cbi-section .cbi-value-title{max-width:820px!important;text-align:left!important;font-size:13px!important;font-weight:650!important}
.cbi-section .cbi-value-field,.cbi-section .cbi-value-description{max-width:820px!important}
.cbi-section .cbi-value-description{text-align:left!important;font-size:11px!important;line-height:1.5!important}
.cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-section .cbi-value-field select,.cbi-section .cbi-value-field textarea{min-height:40px!important;border-radius:8px!important}
.cbi-section .cbi-value-field label:has(input[type=radio]),.cbi-section .cbi-value-field label:has(input[type=checkbox]){display:flex!important;align-items:center;gap:8px;padding:10px 12px!important;margin:4px 0!important;border:1px solid var(--border-color,rgba(128,128,128,.25));border-radius:9px;background:var(--secondary-bg,rgba(128,128,128,.04));font-size:13px!important;line-height:1.45!important}
.cbi-section .cbi-value-field input[type=radio],.cbi-section .cbi-value-field input[type=checkbox]{transform:scale(1.05);margin:0 5px 0 0!important}
.hinfan-help{max-width:1180px;margin:14px auto 20px!important;padding:14px 17px!important;font-size:13px!important}
@media(max-width:900px){
 .hinfan-card,.cbi-map{max-width:100%!important}
 .hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important}
 .cbi-section{padding:14px 16px 18px!important}
}
@media(max-width:600px){
 .hinfan-hero{padding:15px!important;border-radius:12px!important}
 .hinfan-hero-main{align-items:flex-start!important;flex-direction:column;gap:5px}
 .hinfan-grid{grid-template-columns:minmax(0,1fr)!important;gap:9px!important}
 .hinfan-tile{padding:13px 15px!important}
 .hinfan-tile-v{font-size:25px!important}
 .hinfan-curve-panel{padding:12px!important;margin-top:10px}
 .hinfan-panel-heading{align-items:flex-start;flex-direction:column;gap:3px}
 .hinfan-curve-current svg{min-height:0!important}
 .cbi-section{padding:12px 12px 15px!important;border-radius:11px!important}
 .cbi-section .cbi-value{padding:10px 0!important}
 .cbi-section .cbi-value-title,.cbi-section .cbi-value-field,.cbi-section .cbi-value-description{max-width:100%!important;width:100%!important}
 .cbi-section .cbi-value-field ul{display:flex;flex-direction:column;gap:7px!important}
 .cbi-section .cbi-value-field ul li{width:100%;box-sizing:border-box}
}
@media(prefers-reduced-motion:reduce){.hinfan-tile,.hinfan-bar span{transition:none!important}}


/* 1.4.3：按蓝白效果图统一仪表盘视觉；覆盖旧版累积样式 */
.hinfan-card{color:#172b4d!important;width:100%;max-width:1180px;margin:0 auto 22px!important;box-sizing:border-box}
.hinfan-hero{background:linear-gradient(120deg,#1d4ed8 0%,#3b82f6 55%,#60a5fa 100%)!important;color:#fff!important;border:1px solid rgba(37,99,235,.18)!important;box-shadow:0 8px 24px rgba(37,99,235,.18)!important;border-radius:16px!important;padding:18px 22px!important}
.hinfan-hero.bad{background:linear-gradient(120deg,#b91c1c,#ef4444)!important}
.hinfan-hero.warn{background:linear-gradient(120deg,#b45309,#f59e0b)!important}
.hinfan-hero.info{background:linear-gradient(120deg,#1d4ed8,#60a5fa)!important}
.hinfan-grid{display:grid!important;grid-template-columns:repeat(4,minmax(0,1fr))!important;gap:12px!important;margin:0!important;align-items:stretch!important}
.hinfan-tile{min-width:0!important;padding:16px!important;border:1px solid #dbeafe!important;border-radius:14px!important;background:linear-gradient(180deg,#fff 0%,#f8fbff 100%)!important;color:#172b4d!important;box-shadow:0 4px 14px rgba(30,64,175,.07)!important}
.hinfan-tile-k{color:#52709a!important;font-size:13px!important;font-weight:650!important;letter-spacing:.02em;margin-bottom:9px!important}
.hinfan-tile-v{color:#173b73!important;font-size:clamp(22px,2.4vw,30px)!important;font-weight:800!important;line-height:1.2!important;font-variant-numeric:tabular-nums}
.hinfan-unit,.hinfan-tile-s{color:#6882a6!important}
.hinfan-t-ok{color:#16845b!important}.hinfan-t-info{color:#2563eb!important}.hinfan-t-warn{color:#c27a12!important}.hinfan-t-hot,.hinfan-t-bad{color:#dc2626!important}
.hinfan-bar{background:#e5eefc!important}.hinfan-bar span{background:linear-gradient(90deg,#2563eb,#60a5fa)!important}
.hinfan-fanwrap{color:#2563eb!important}.hinfan-fan-slow,.hinfan-fan-mid{color:#2563eb!important}
.hinfan-curve-panel{border:1px solid #dbeafe!important;border-radius:14px!important;background:linear-gradient(180deg,#fff,#f7faff)!important;box-shadow:0 4px 14px rgba(30,64,175,.055)}
.hinfan-curve-current{border:0!important;background:transparent!important}
.hinfan-curve-caption{color:#6882a6!important;opacity:1!important}
.hinfan-panel-heading{color:#1e40af!important}
.hinfan-note,.hinfan-help{background:#eff6ff!important;border:1px solid #dbeafe!important;border-left:4px solid #3b82f6!important;color:#24436d!important;border-radius:11px!important}
.cbi-map{width:100%!important;max-width:1180px!important;margin-left:auto!important;margin-right:auto!important;box-sizing:border-box!important}
.cbi-section{border:1px solid #dbeafe!important;border-radius:14px!important;background:#fff!important;box-shadow:0 5px 18px rgba(30,64,175,.055)!important;color:#172b4d!important;padding:16px 20px 20px!important}
.cbi-section>legend{background:linear-gradient(90deg,#eff6ff,#fff)!important;color:#1e40af!important;border-left:4px solid #3b82f6!important;border-radius:9px!important}
.cbi-section .cbi-section-descr,.cbi-value-description{color:#647b9c!important}
.cbi-value-title{color:#24436d!important}
.cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-value-field select,.cbi-value-field textarea{background:#fff!important;color:#172b4d!important;border:1px solid #cbdcf5!important;border-radius:9px!important;min-height:40px!important;box-sizing:border-box!important}
.cbi-value-field input:focus,.cbi-value-field select:focus,.cbi-value-field textarea:focus{border-color:#3b82f6!important;box-shadow:0 0 0 3px rgba(59,130,246,.14)!important}
.cbi-value-field input[type=radio],.cbi-value-field input[type=checkbox]{accent-color:#2563eb!important}
.cbi-value-field ul li,.cbi-value-field label:has(input[type=radio]),.cbi-value-field label:has(input[type=checkbox]){background:#f7faff!important;border-color:#dbeafe!important;color:#24436d!important}
.cbi-value-field ul li:hover,.cbi-value-field label:has(input[type=radio]):hover,.cbi-value-field label:has(input[type=checkbox]):hover{background:#eff6ff!important;border-color:#93c5fd!important}
@media(max-width:900px){.hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important}.hinfan-card,.cbi-map{max-width:100%!important}}
@media(max-width:600px){
 .cbi-map,.cbi-map>form{width:100%!important;max-width:100%!important;min-width:0!important;overflow-x:hidden!important}
 .hinfan-card{width:100%!important;max-width:100%!important}
 .hinfan-hero{padding:14px!important;margin-bottom:11px!important;border-radius:12px!important}
 .hinfan-hero-main{gap:7px!important;font-size:14px!important}
 .hinfan-hero-sub{font-size:11px!important;line-height:1.5!important;overflow-wrap:anywhere!important}
 .hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important}
 .hinfan-tile{padding:11px!important;border-radius:11px!important}
 .hinfan-tile-k{font-size:11px!important}
 .hinfan-tile-v{font-size:clamp(17px,5vw,22px)!important}
 .hinfan-tile-s{font-size:10px!important;overflow-wrap:anywhere!important}
 .hinfan-curve-panel{padding:12px!important;margin-top:10px!important;min-width:0!important}
 .hinfan-panel-heading{align-items:flex-start;flex-direction:column;gap:3px}
 .hinfan-curve-current svg{width:100%!important;max-width:100%!important;height:auto!important;min-height:0!important}
 .cbi-section{width:100%!important;max-width:100%!important;min-width:0!important;box-sizing:border-box!important;padding:10px 11px 12px!important;margin-bottom:12px!important}
 .cbi-section>legend{width:auto!important;margin:0 0 10px!important;padding:10px 11px!important;font-size:14px!important}
 .cbi-section .cbi-value{display:flex!important;flex-direction:column!important;align-items:stretch!important;width:100%!important;max-width:100%!important;padding:9px 0!important;gap:5px!important}
 .cbi-section .cbi-value-title,.cbi-section .cbi-value-field,.cbi-section .cbi-value-description{width:100%!important;max-width:100%!important;min-width:0!important;text-align:left!important}
 .cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-value-field select,.cbi-value-field textarea{width:100%!important;max-width:100%!important;min-height:43px!important;font-size:16px!important}
 .cbi-value-field .cbi-dynlist{width:100%!important;max-width:100%!important}
 .cbi-value-field .cbi-dynlist input:not([type=radio]):not([type=checkbox]){width:calc(100% - 42px)!important;max-width:calc(100% - 42px)!important}
 .cbi-value-field ul{width:100%!important;max-width:100%!important}
 .cbi-value-field ul li,.cbi-value-field label:has(input[type=radio]),.cbi-value-field label:has(input[type=checkbox]){width:100%!important;max-width:100%!important;min-height:40px!important;box-sizing:border-box!important;white-space:normal!important}
}
@media(max-width:380px){.hinfan-grid{gap:6px!important}.hinfan-tile{padding:8px!important}.hinfan-tile-v{font-size:16px!important}.hinfan-curve-caption{font-size:9px!important}}
/* 暗色主题：蓝色强调不变，主体切换为深蓝灰 */
html[data-darkmode="true"] .hinfan-card,html.dark .hinfan-card,body.dark .hinfan-card{color:#e5edf9!important}
html[data-darkmode="true"] .hinfan-tile,html.dark .hinfan-tile,body.dark .hinfan-tile{background:linear-gradient(180deg,#202b3b,#1b2635)!important;border-color:#344966!important;color:#e5edf9!important}
html[data-darkmode="true"] .hinfan-tile-v,html.dark .hinfan-tile-v,body.dark .hinfan-tile-v{color:#dbeafe!important}
html[data-darkmode="true"] .hinfan-tile-k,html.dark .hinfan-tile-k,body.dark .hinfan-tile-k,html[data-darkmode="true"] .hinfan-unit,html.dark .hinfan-unit,body.dark .hinfan-unit,html[data-darkmode="true"] .hinfan-tile-s,html.dark .hinfan-tile-s,body.dark .hinfan-tile-s{color:#a9bdd8!important}
html[data-darkmode="true"] .hinfan-curve-panel,html.dark .hinfan-curve-panel,body.dark .hinfan-curve-panel,html[data-darkmode="true"] .hinfan-curve-current,html.dark .hinfan-curve-current,body.dark .hinfan-curve-current{background:#1b2635!important;border-color:#344966!important}
html[data-darkmode="true"] .hinfan-panel-heading,html.dark .hinfan-panel-heading,body.dark .hinfan-panel-heading{color:#bfdbfe!important}
html[data-darkmode="true"] .hinfan-note,html.dark .hinfan-note,body.dark .hinfan-note,html[data-darkmode="true"] .hinfan-help,html.dark .hinfan-help,body.dark .hinfan-help{background:#1e3048!important;border-color:#34557f!important;color:#dbeafe!important}
html[data-darkmode="true"] .cbi-section,html.dark .cbi-section,body.dark .cbi-section{background:#1c2635!important;border-color:#344966!important;color:#e5edf9!important}
html[data-darkmode="true"] .cbi-section>legend,html.dark .cbi-section>legend,body.dark .cbi-section>legend{background:#26364b!important;color:#dbeafe!important}
html[data-darkmode="true"] .cbi-value-title,html.dark .cbi-value-title,body.dark .cbi-value-title,html[data-darkmode="true"] .cbi-value-description,html.dark .cbi-value-description,body.dark .cbi-value-description{color:#b6c7df!important}
html[data-darkmode="true"] .cbi-value-field input:not([type=radio]):not([type=checkbox]),html.dark .cbi-value-field input:not([type=radio]):not([type=checkbox]),body.dark .cbi-value-field input:not([type=radio]):not([type=checkbox]),html[data-darkmode="true"] .cbi-value-field select,html.dark .cbi-value-field select,body.dark .cbi-value-field select,html[data-darkmode="true"] .cbi-value-field textarea,html.dark .cbi-value-field textarea,body.dark .cbi-value-field textarea{background:#202b3b!important;color:#e5edf9!important;border-color:#405675!important}
html[data-darkmode="true"] .cbi-value-field ul li,html.dark .cbi-value-field ul li,body.dark .cbi-value-field ul li,html[data-darkmode="true"] .cbi-value-field label:has(input[type=radio]),html.dark .cbi-value-field label:has(input[type=radio]),body.dark .cbi-value-field label:has(input[type=radio]){background:#243449!important;border-color:#405675!important;color:#dbeafe!important}


/* 1.4.3 蓝白效果图：把控制模式与预设选项呈现为可点击的卡片 */
.cbi-value-field ul:has(input[type="radio"]){
 display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr))!important;
 gap:10px!important;width:100%!important;margin:0!important;padding:0!important;
}
.cbi-value-field ul:has(input[type="radio"]) li{
 display:flex!important;align-items:center!important;min-width:0!important;
 min-height:58px!important;padding:12px 14px!important;
 border:1px solid #d7e5f8!important;border-radius:12px!important;
 background:linear-gradient(145deg,#fff,#f4f8ff)!important;
 box-shadow:0 3px 10px rgba(37,99,235,.055)!important;
}
.cbi-value-field ul:has(input[type="radio"]) li:has(input:checked){
 border:1.5px solid #3b82f6!important;
 background:linear-gradient(145deg,#eaf3ff,#f7fbff)!important;
 box-shadow:0 0 0 3px rgba(59,130,246,.10)!important;
}
.cbi-value-field ul:has(input[type="radio"]) li label{
 display:flex!important;align-items:center!important;gap:9px!important;
 width:100%!important;min-width:0!important;font-weight:650!important;
}
.cbi-value-field ul:has(input[type="radio"]) input[type="radio"]{
 flex:0 0 auto!important;width:17px!important;height:17px!important;
 accent-color:#2563eb!important;
}
@media(max-width:600px){
 .cbi-value-field ul:has(input[type="radio"]){grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:7px!important}
 .cbi-value-field ul:has(input[type="radio"]) li{min-height:52px!important;padding:9px!important}
}
html[data-darkmode="true"] .cbi-value-field ul:has(input[type="radio"]) li,
html.dark .cbi-value-field ul:has(input[type="radio"]) li,
body.dark .cbi-value-field ul:has(input[type="radio"]) li{
 background:linear-gradient(145deg,#243449,#1d2a3b)!important;
 border-color:#405675!important;color:#dbeafe!important;
}
html[data-darkmode="true"] .cbi-value-field ul:has(input[type="radio"]) li:has(input:checked),
html.dark .cbi-value-field ul:has(input[type="radio"]) li:has(input:checked),
body.dark .cbi-value-field ul:has(input[type="radio"]) li:has(input:checked){
 border-color:#60a5fa!important;background:#263d5b!important;
}


/* 1.5.0：真正分区的控制台布局，不再把所有字段堆进同一个 CBI 表单 */
.hinfan-card{margin-bottom:22px!important}
.hinfan-hero{background:linear-gradient(115deg,#1768d5 0%,#3989f5 58%,#67b5ff 100%)!important;border:1px solid rgba(255,255,255,.22)!important;box-shadow:0 12px 28px rgba(37,99,235,.18)!important}
.hinfan-grid{gap:14px!important;margin-bottom:18px!important}
.hinfan-tile{padding:17px!important;border:1px solid #d8e6fa!important;border-radius:15px!important;background:linear-gradient(160deg,#fff 0%,#f5f9ff 100%)!important;box-shadow:0 7px 20px rgba(31,78,145,.07)!important}
.hinfan-tile-k{font-size:13px!important;letter-spacing:.025em!important}
.hinfan-tile-v{font-size:clamp(25px,2.8vw,34px)!important}
.cbi-map{max-width:1240px!important}
.cbi-section{position:relative!important;margin:0 0 20px!important;padding:18px 22px 22px!important;border:1px solid #d8e6fa!important;border-radius:16px!important;background:linear-gradient(180deg,#fff 0%,#fbfdff 100%)!important;box-shadow:0 8px 24px rgba(31,78,145,.065)!important}
.cbi-section>legend{width:auto!important;margin:0 0 14px!important;padding:13px 16px!important;border:0!important;border-left:4px solid #347ff0!important;border-radius:9px!important;background:linear-gradient(90deg,#edf5ff,#f9fbff)!important;color:#174b91!important;font-size:17px!important;font-weight:800!important}
.cbi-section .cbi-section-descr{max-width:100%!important;margin:0 0 14px!important;padding:0 2px!important;color:#617b9e!important;font-size:13px!important;line-height:1.8!important}
.cbi-section .cbi-value{display:grid!important;grid-template-columns:minmax(180px,28%) minmax(0,1fr)!important;align-items:center!important;column-gap:22px!important;row-gap:5px!important;padding:13px 5px!important;border-bottom:1px solid #edf2fa!important}
.cbi-section .cbi-value-title{max-width:none!important;text-align:left!important;font-weight:750!important;color:#29496f!important}
.cbi-section .cbi-value-field{max-width:none!important;width:100%!important}
.cbi-section .cbi-value-description{grid-column:2!important;max-width:none!important;margin:0!important;text-align:left!important;color:#7186a4!important}
.cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-section .cbi-value-field select,.cbi-section .cbi-value-field textarea{max-width:100%!important}
.cbi-section:nth-of-type(2) .cbi-value-field ul:has(input[type=radio]){grid-template-columns:repeat(2,minmax(0,1fr))!important}
.cbi-section:nth-of-type(3) .cbi-value{grid-template-columns:minmax(160px,25%) minmax(0,1fr)!important}
.cbi-section:nth-of-type(3) .cbi-value-field{padding:10px 13px!important;border:1px solid #e2ecf9!important;border-radius:9px!important;background:#f7faff!important;color:#23466f!important;overflow-wrap:anywhere!important}
html[data-darkmode="true"] .cbi-section,html.dark .cbi-section,body.dark .cbi-section{background:linear-gradient(180deg,#1d2b3e,#192638)!important;border-color:#344d6d!important}
html[data-darkmode="true"] .cbi-section>legend,html.dark .cbi-section>legend,body.dark .cbi-section>legend{background:linear-gradient(90deg,#263d5c,#203149)!important;color:#dbeafe!important}
html[data-darkmode="true"] .cbi-section .cbi-value-title,html.dark .cbi-section .cbi-value-title,body.dark .cbi-section .cbi-value-title{color:#c8dcf7!important}
html[data-darkmode="true"] .cbi-section .cbi-value-field,html.dark .cbi-section .cbi-value-field,body.dark .cbi-section .cbi-value-field{color:#dbeafe!important}
html[data-darkmode="true"] .cbi-section:nth-of-type(3) .cbi-value-field,html.dark .cbi-section:nth-of-type(3) .cbi-value-field,body.dark .cbi-section:nth-of-type(3) .cbi-value-field{background:#24364e!important;border-color:#405a7a!important;color:#dbeafe!important}
@media(max-width:700px){
 .hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:9px!important}
 .hinfan-tile{padding:12px!important}
 .cbi-section{padding:12px!important;margin-bottom:13px!important}
 .cbi-section>legend{font-size:15px!important;padding:10px 12px!important}
 .cbi-section .cbi-value,.cbi-section:nth-of-type(3) .cbi-value{grid-template-columns:minmax(0,1fr)!important;gap:7px!important;padding:11px 2px!important}
 .cbi-section .cbi-value-title,.cbi-section .cbi-value-field,.cbi-section .cbi-value-description{grid-column:1!important;width:100%!important;max-width:100%!important;text-align:left!important}
 .cbi-section .cbi-value-description{margin-top:2px!important}
}
/* 1.5.1：设备树 / 内核状态详情整合进顶部内核档位卡片 */
.hinfan-kernel-tile{grid-column:auto!important}
.hinfan-kernel-details{margin-top:12px;border-top:1px solid #dce8f7;padding-top:9px}
.hinfan-kernel-details>summary{cursor:pointer;display:inline-flex;align-items:center;gap:7px;color:#2563c7;font-size:12px;font-weight:750;min-height:34px}
.hinfan-kernel-content{margin-top:9px;padding:10px 12px;border:1px solid #dce8f7;border-radius:10px;background:#f7faff}
.hinfan-kernel-intro{font-size:12px;line-height:1.7;color:#607895;margin-bottom:9px}
.hinfan-kernel-content .hinfan-help{margin-bottom:10px}
.hinfan-kv{display:grid;grid-template-columns:minmax(120px,30%) minmax(0,1fr);gap:10px;padding:8px 2px;border-bottom:1px solid #e5edf8;font-size:12px;line-height:1.65}
.hinfan-kv:last-child{border-bottom:0}
.hinfan-kv b{color:#31547f}
.hinfan-kv span{min-width:0;overflow-wrap:anywhere;color:#29496f}
html[data-darkmode="true"] .hinfan-kernel-details,html.dark .hinfan-kernel-details,body.dark .hinfan-kernel-details{border-color:#405675}
html[data-darkmode="true"] .hinfan-kernel-details>summary,html.dark .hinfan-kernel-details>summary,body.dark .hinfan-kernel-details>summary{color:#93c5fd}
html[data-darkmode="true"] .hinfan-kernel-content,html.dark .hinfan-kernel-content,body.dark .hinfan-kernel-content{background:#24364e;border-color:#405a7a}
html[data-darkmode="true"] .hinfan-kernel-intro,html.dark .hinfan-kernel-intro,body.dark .hinfan-kernel-intro,html[data-darkmode="true"] .hinfan-kv b,html.dark .hinfan-kv b,body.dark .hinfan-kv b,html[data-darkmode="true"] .hinfan-kv span,html.dark .hinfan-kv span,body.dark .hinfan-kv span{color:#dbeafe}
html[data-darkmode="true"] .hinfan-kv,html.dark .hinfan-kv,body.dark .hinfan-kv{border-color:#405675}
@media(max-width:700px){.hinfan-kernel-tile{grid-column:1/-1!important}.hinfan-kv{grid-template-columns:minmax(0,1fr)!important;gap:3px!important}.hinfan-kv span{padding-left:2px}}

/* 1.5.2：页面横向铺满可用空间，修复暗色主题文字对比度 */
.main .container:has(.hinfan-card){width:100%!important;max-width:none!important;box-sizing:border-box!important}
.cbi-map{width:100%!important;max-width:none!important;margin-left:0!important;margin-right:0!important;box-sizing:border-box!important}
.cbi-map > .cbi-section,.cbi-map > .cbi-section-node,.cbi-section{width:100%!important;max-width:none!important;box-sizing:border-box!important}
.cbi-section .cbi-value,.cbi-section .cbi-section-descr{max-width:none!important}
.hinfan-card,.hinfan-curve-panel{width:100%!important;max-width:none!important;box-sizing:border-box!important}
.hinfan-curve-current{max-width:none!important}
.hinfan-curve-current svg{max-width:100%!important}
@media(min-width:768px){
 .cbi-section{padding-left:clamp(18px,2.2vw,34px)!important;padding-right:clamp(18px,2.2vw,34px)!important}
 .cbi-section .cbi-value{grid-template-columns:minmax(210px,24%) minmax(0,1fr)!important}
}
@media(max-width:767px){
 .main .container:has(.hinfan-card){padding-left:10px!important;padding-right:10px!important}
 .cbi-map,.cbi-section{width:100%!important;max-width:none!important}
}
/* 暗色模式：覆盖表单说明、字段、曲线节点、折叠详情等低对比文字 */
html[data-darkmode="true"] .hinfan-card,
html[data-theme="dark"] .hinfan-card,
html.dark .hinfan-card,body.dark .hinfan-card{color:#f1f5fb!important}
html[data-darkmode="true"] .hinfan-tile-k,html[data-theme="dark"] .hinfan-tile-k,html.dark .hinfan-tile-k,body.dark .hinfan-tile-k,
html[data-darkmode="true"] .hinfan-tile-s,html[data-theme="dark"] .hinfan-tile-s,html.dark .hinfan-tile-s,body.dark .hinfan-tile-s,
html[data-darkmode="true"] .hinfan-unit,html[data-theme="dark"] .hinfan-unit,html.dark .hinfan-unit,body.dark .hinfan-unit{color:#cbd8e9!important}
html[data-darkmode="true"] .hinfan-tile-v,html[data-theme="dark"] .hinfan-tile-v,html.dark .hinfan-tile-v,body.dark .hinfan-tile-v{color:#f1f5fb!important}
html[data-darkmode="true"] .hinfan-t-ok,html[data-theme="dark"] .hinfan-t-ok,html.dark .hinfan-t-ok,body.dark .hinfan-t-ok{color:#6ee7b7!important}
html[data-darkmode="true"] .hinfan-t-info,html[data-theme="dark"] .hinfan-t-info,html.dark .hinfan-t-info,body.dark .hinfan-t-info{color:#93c5fd!important}
html[data-darkmode="true"] .hinfan-t-warn,html[data-theme="dark"] .hinfan-t-warn,html.dark .hinfan-t-warn,body.dark .hinfan-t-warn{color:#fcd34d!important}
html[data-darkmode="true"] .hinfan-t-hot,html[data-theme="dark"] .hinfan-t-hot,html.dark .hinfan-t-hot,body.dark .hinfan-t-hot,
html[data-darkmode="true"] .hinfan-t-bad,html[data-theme="dark"] .hinfan-t-bad,html.dark .hinfan-t-bad,body.dark .hinfan-t-bad{color:#fca5a5!important}
html[data-darkmode="true"] .cbi-section .cbi-section-descr,html[data-theme="dark"] .cbi-section .cbi-section-descr,html.dark .cbi-section .cbi-section-descr,body.dark .cbi-section .cbi-section-descr,
html[data-darkmode="true"] .cbi-value-title,html[data-theme="dark"] .cbi-value-title,html.dark .cbi-value-title,body.dark .cbi-value-title,
html[data-darkmode="true"] .cbi-value-description,html[data-theme="dark"] .cbi-value-description,html.dark .cbi-value-description,body.dark .cbi-value-description{color:#d2deed!important}
html[data-darkmode="true"] .cbi-value-field,html[data-theme="dark"] .cbi-value-field,html.dark .cbi-value-field,body.dark .cbi-value-field{color:#f1f5fb!important}
html[data-darkmode="true"] .cbi-value-field input,html[data-theme="dark"] .cbi-value-field input,html.dark .cbi-value-field input,body.dark .cbi-value-field input,
html[data-darkmode="true"] .cbi-value-field select,html[data-theme="dark"] .cbi-value-field select,html.dark .cbi-value-field select,body.dark .cbi-value-field select,
html[data-darkmode="true"] .cbi-value-field textarea,html[data-theme="dark"] .cbi-value-field textarea,html.dark .cbi-value-field textarea,body.dark .cbi-value-field textarea{background:#172638!important;color:#f8fafc!important;border-color:#526b89!important}
html[data-darkmode="true"] .cbi-value-field input::placeholder,html[data-theme="dark"] .cbi-value-field input::placeholder,html.dark .cbi-value-field input::placeholder,body.dark .cbi-value-field input::placeholder{color:#a9bad0!important;opacity:1!important}
html[data-darkmode="true"] .cbi-value-field ul li,html[data-theme="dark"] .cbi-value-field ul li,html.dark .cbi-value-field ul li,body.dark .cbi-value-field ul li,
html[data-darkmode="true"] .cbi-value-field label,html[data-theme="dark"] .cbi-value-field label,html.dark .cbi-value-field label,body.dark .cbi-value-field label{color:#edf4ff!important}
html[data-darkmode="true"] .hinfan-kernel-intro,html[data-theme="dark"] .hinfan-kernel-intro,html.dark .hinfan-kernel-intro,body.dark .hinfan-kernel-intro,
html[data-darkmode="true"] .hinfan-kv b,html[data-theme="dark"] .hinfan-kv b,html.dark .hinfan-kv b,body.dark .hinfan-kv b,
html[data-darkmode="true"] .hinfan-kv span,html[data-theme="dark"] .hinfan-kv span,html.dark .hinfan-kv span,body.dark .hinfan-kv span{color:#e2ecf8!important}
html[data-darkmode="true"] .hinfan-curve-caption,html[data-theme="dark"] .hinfan-curve-caption,html.dark .hinfan-curve-caption,body.dark .hinfan-curve-caption{color:#cbd8e9!important;opacity:1!important}
html[data-darkmode="true"] .hinfan-curve-panel,html[data-theme="dark"] .hinfan-curve-panel,html.dark .hinfan-curve-panel,body.dark .hinfan-curve-panel{color:#e5edf8!important}


/* 顶栏响应式优化：桌面横向分区，手机纵向堆叠 */
.hinfan-hero{
  display:flex!important;
  align-items:center!important;
  justify-content:space-between!important;
  gap:14px!important;
  min-width:0!important;
  padding:18px clamp(14px,2vw,24px)!important;
}
.hinfan-hero-main{
  flex:1 1 auto!important;
  min-width:0!important;
  gap:10px 12px!important;
}
.hinfan-badge{
  flex:0 0 auto!important;
  display:inline-flex!important;
  align-items:center!important;
  justify-content:center!important;
  min-height:34px!important;
  padding:6px 13px!important;
  border:1px solid rgba(255,255,255,.32)!important;
  border-radius:9px!important;
  background:rgba(255,255,255,.16)!important;
  line-height:1.35!important;
}
.hinfan-hero-note{
  min-width:0!important;
  line-height:1.65!important;
  overflow-wrap:anywhere!important;
}
.hinfan-hero-sub{
  flex:0 1 auto!important;
  min-width:0!important;
  max-width:42%!important;
  margin:0!important;
  padding:8px 11px!important;
  border:1px solid rgba(255,255,255,.24)!important;
  border-radius:9px!important;
  background:rgba(8,42,94,.14)!important;
  line-height:1.55!important;
  overflow-wrap:anywhere!important;
}
@media(max-width:900px){
  .hinfan-hero{align-items:flex-start!important;gap:10px!important}
  .hinfan-hero-sub{max-width:48%!important;font-size:11px!important}
}
@media(max-width:600px){
  .hinfan-hero{
    display:flex!important;
    flex-direction:column!important;
    align-items:stretch!important;
    gap:10px!important;
    padding:14px!important;
    border-radius:12px!important;
  }
  .hinfan-hero-main{
    display:flex!important;
    flex-direction:column!important;
    align-items:flex-start!important;
    gap:7px!important;
    width:100%!important;
  }
  .hinfan-badge{min-height:32px!important;font-size:15px!important}
  .hinfan-hero-note{font-size:12px!important;line-height:1.6!important}
  .hinfan-hero-sub{
    display:block!important;
    width:100%!important;
    max-width:none!important;
    box-sizing:border-box!important;
    padding:8px 10px!important;
    font-size:11px!important;
    line-height:1.6!important;
  }
}
@media(prefers-reduced-motion:reduce){
  .hinfan-hero,.hinfan-hero *{transition:none!important}
}

/* 1.5.2：恢复截图中的经典布局；桌面左右分栏，手机纵向堆叠，亮/暗主题独立配色 */
.hinfan-card{width:100%!important;max-width:none!important;margin:0 0 18px!important;color:var(--content-color,#203047)!important}
.hinfan-hero{background:linear-gradient(115deg,#20b985 0%,#35c995 55%,#51d9a5 100%)!important;color:#fff!important;border:0!important;border-radius:15px!important;padding:17px 21px!important;box-shadow:0 7px 20px rgba(20,180,125,.16)!important}
.hinfan-hero.bad{background:linear-gradient(115deg,#b83246,#e65353)!important}
.hinfan-hero.warn{background:linear-gradient(115deg,#bb791d,#e5a43d)!important}
.hinfan-hero.info{background:linear-gradient(115deg,#2766bb,#498ce2)!important}
.hinfan-grid{display:grid!important;grid-template-columns:repeat(4,minmax(0,1fr))!important;gap:12px!important;margin:0 0 14px!important;align-items:stretch!important}
.hinfan-tile{min-width:0!important;padding:15px!important;border:1px solid #e5eaf1!important;border-radius:14px!important;background:#fff!important;color:#26364d!important;box-shadow:0 3px 10px rgba(25,45,75,.07)!important}
.hinfan-tile-k{font-size:13px!important;color:#71839c!important;font-weight:600!important;margin-bottom:8px!important}
.hinfan-tile-v{font-size:clamp(23px,2.5vw,31px)!important;line-height:1.2!important;color:#203b66!important;font-weight:800!important}
.hinfan-unit,.hinfan-tile-s{color:#8494aa!important}
.hinfan-t-ok{color:#25bd88!important}.hinfan-t-info{color:#4389e8!important}.hinfan-t-warn{color:#d89a36!important}.hinfan-t-hot,.hinfan-t-bad{color:#e45c62!important}
.hinfan-bar{background:#e7edf3!important}.hinfan-bar span{background:linear-gradient(90deg,#25c6c4,#5579ef)!important}
.hinfan-fanwrap{color:inherit!important}
.hinfan-kernel-tile .hinfan-tile-v{color:#203b66!important}
.hinfan-kernel-strip{box-sizing:border-box;width:100%;margin:0 0 12px;padding:11px 15px;border-left:4px solid #6678ff;border-radius:8px;background:#edf1fb;color:#405779;font-size:13px;line-height:1.5}
.hinfan-help{box-sizing:border-box;width:100%;max-width:none!important;margin:0 0 14px!important;padding:12px 15px!important;border:0!important;border-radius:10px!important;border-left:3px solid #6678ff!important;background:#f0f2f5!important;color:#53677f!important;font-size:12px!important;line-height:1.75!important}
.hinfan-kernel-details{margin:0 0 16px;padding:0 2px 10px;border-bottom:1px solid #e5eaf1}
.hinfan-kernel-details>summary{cursor:pointer;color:#386fc1;font-size:12px;font-weight:700;padding:5px 0}
.hinfan-kernel-content{margin-top:8px;padding:10px 12px;border:1px solid #e0e8f3;border-radius:9px;background:#f8faff}
.hinfan-kernel-intro,.hinfan-kv,.hinfan-kv b,.hinfan-kv span{color:#53677f}
.cbi-map{width:100%!important;max-width:none!important;margin:0!important;box-sizing:border-box!important}
.cbi-section{display:block!important;box-sizing:border-box!important;margin:0 0 18px!important;padding:14px 18px 18px!important;border:1px solid #e3eaf3!important;border-radius:14px!important;background:#fff!important;color:#26364d!important;box-shadow:0 4px 14px rgba(25,45,75,.06)!important;overflow:visible!important}
.cbi-section>legend{display:block!important;box-sizing:border-box!important;width:auto!important;margin:0 0 10px!important;padding:11px 14px!important;border:0!important;border-left:4px solid #6678ff!important;border-radius:8px!important;background:#f5f7fc!important;color:#344f78!important;font-size:16px!important;font-weight:750!important}
.cbi-section .cbi-section-descr{max-width:none!important;margin:4px 0 12px!important;padding:0 2px!important;text-align:left!important;color:#7b8da5!important;font-size:12px!important;line-height:1.7!important}
.cbi-section .cbi-value{display:grid!important;grid-template-columns:minmax(170px,25%) minmax(0,1fr)!important;align-items:start!important;column-gap:20px!important;row-gap:5px!important;width:100%!important;max-width:none!important;margin:0!important;padding:11px 3px!important;border:0!important;border-bottom:1px solid #edf1f6!important}
.cbi-section .cbi-value:last-child{border-bottom:0!important}
.cbi-section .cbi-value-title{grid-column:1!important;width:auto!important;max-width:none!important;margin:0!important;padding:7px 0 0!important;text-align:left!important;color:#3f5879!important;font-size:13px!important;font-weight:700!important;line-height:1.5!important}
.cbi-section .cbi-value-field{grid-column:2!important;width:100%!important;max-width:none!important;min-width:0!important;margin:0!important;padding:0!important;text-align:left!important}
.cbi-section .cbi-value-description{grid-column:2!important;width:100%!important;max-width:none!important;margin:3px 0 0!important;text-align:left!important;color:#8191a7!important;font-size:11px!important;line-height:1.55!important}
.cbi-section .cbi-value-field ul{display:flex!important;flex-direction:column!important;align-items:stretch!important;gap:5px!important;width:100%!important;margin:0!important;padding:0!important;list-style:none!important}
.cbi-section .cbi-value-field ul li{display:block!important;box-sizing:border-box!important;width:100%!important;min-height:0!important;margin:0!important;padding:5px 2px!important;border:0!important;border-radius:0!important;background:transparent!important;color:#3d5575!important;line-height:1.55!important}
.cbi-section .cbi-value-field ul li label,.cbi-section .cbi-value-field label:has(input[type=radio]),.cbi-section .cbi-value-field label:has(input[type=checkbox]){display:inline-flex!important;align-items:center!important;gap:7px!important;margin:0!important;padding:3px 2px!important;border:0!important;background:transparent!important;color:inherit!important;font-size:13px!important;line-height:1.55!important;white-space:normal!important}
.cbi-section .cbi-value-field input[type=radio],.cbi-section .cbi-value-field input[type=checkbox]{width:16px!important;height:16px!important;flex:0 0 auto!important;margin:0 4px 0 0!important;accent-color:#6678ff!important}
.cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),.cbi-section .cbi-value-field select,.cbi-section .cbi-value-field textarea{box-sizing:border-box!important;width:100%!important;max-width:100%!important;min-height:39px!important;padding:8px 10px!important;border:1px solid #d5deea!important;border-radius:8px!important;background:#fff!important;color:#26364d!important;box-shadow:none!important}
.cbi-section .cbi-value-field input:focus,.cbi-section .cbi-value-field select:focus,.cbi-section .cbi-value-field textarea:focus{outline:0!important;border-color:#7b91ed!important;box-shadow:0 0 0 3px rgba(102,120,255,.13)!important}
.cbi-section .cbi-value-field .cbi-dynlist{width:100%!important;max-width:100%!important}
.cbi-section .cbi-value-field .cbi-dynlist input:not([type=radio]):not([type=checkbox]){width:calc(100% - 40px)!important;max-width:calc(100% - 40px)!important}
@media(max-width:900px){.hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:9px!important}.hinfan-tile{padding:12px!important}}
@media(max-width:700px){
 .cbi-map,.cbi-map>form{width:100%!important;max-width:100%!important;min-width:0!important;overflow-x:hidden!important}
 .cbi-section{padding:11px 12px 14px!important;margin-bottom:13px!important}
 .cbi-section .cbi-value{grid-template-columns:minmax(0,1fr)!important;row-gap:5px!important;padding:9px 1px!important}
 .cbi-section .cbi-value-title,.cbi-section .cbi-value-field,.cbi-section .cbi-value-description{grid-column:1!important;width:100%!important;max-width:100%!important;text-align:left!important}
 .cbi-section .cbi-value-title{padding:0!important;margin:0 0 2px!important}
 .cbi-section .cbi-value-field ul{gap:5px!important}
 .cbi-section .cbi-value-field ul li{padding:4px 1px!important}
 .hinfan-hero{padding:14px 15px!important}
 .hinfan-hero-main{flex-direction:row!important;align-items:center!important;flex-wrap:wrap!important;gap:8px!important}
 .hinfan-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important;gap:8px!important}
 .hinfan-tile{padding:10px!important;border-radius:11px!important}
 .hinfan-tile-v{font-size:clamp(18px,5vw,24px)!important}
 .hinfan-kv{grid-template-columns:minmax(0,1fr)!important;gap:3px!important}
}
@media(max-width:380px){.hinfan-grid{gap:6px!important}.hinfan-tile{padding:8px!important}.hinfan-tile-v{font-size:17px!important}}
/* 暗色主题只在暗色根节点生效，亮色主题始终保持白底深色字 */
html[data-darkmode="true"] .hinfan-card,html.dark .hinfan-card,body.dark .hinfan-card{color:#e5edf9!important}
html[data-darkmode="true"] .hinfan-tile,html.dark .hinfan-tile,body.dark .hinfan-tile{background:linear-gradient(180deg,#263448,#202c3e)!important;border-color:#3b506c!important;color:#e5edf9!important}
html[data-darkmode="true"] .hinfan-tile-k,html.dark .hinfan-tile-k,body.dark .hinfan-tile-k,html[data-darkmode="true"] .hinfan-unit,html.dark .hinfan-unit,body.dark .hinfan-unit,html[data-darkmode="true"] .hinfan-tile-s,html.dark .hinfan-tile-s,body.dark .hinfan-tile-s{color:#afc1d9!important}
html[data-darkmode="true"] .hinfan-tile-v,html.dark .hinfan-tile-v,body.dark .hinfan-tile-v{color:#e4efff!important}
html[data-darkmode="true"] .hinfan-kernel-strip,html.dark .hinfan-kernel-strip,body.dark .hinfan-kernel-strip{background:#28364e!important;color:#c8d9f1!important;border-left-color:#8290ff!important}
html[data-darkmode="true"] .hinfan-help,html.dark .hinfan-help,body.dark .hinfan-help{background:#273448!important;color:#c5d4e8!important;border-color:#405675!important}
html[data-darkmode="true"] .hinfan-kernel-details,html.dark .hinfan-kernel-details,body.dark .hinfan-kernel-details{border-color:#405675!important}
html[data-darkmode="true"] .hinfan-kernel-details>summary,html.dark .hinfan-kernel-details>summary,body.dark .hinfan-kernel-details>summary{color:#93c5fd!important}
html[data-darkmode="true"] .hinfan-kernel-content,html.dark .hinfan-kernel-content,body.dark .hinfan-kernel-content{background:#24364e!important;border-color:#405a7a!important}
html[data-darkmode="true"] .hinfan-kernel-intro,html.dark .hinfan-kernel-intro,body.dark .hinfan-kernel-intro,html[data-darkmode="true"] .hinfan-kv,html.dark .hinfan-kv,body.dark .hinfan-kv,html[data-darkmode="true"] .hinfan-kv b,html.dark .hinfan-kv b,body.dark .hinfan-kv b,html[data-darkmode="true"] .hinfan-kv span,html.dark .hinfan-kv span,body.dark .hinfan-kv span{color:#c5d8f0!important}
html[data-darkmode="true"] .cbi-section,html.dark .cbi-section,body.dark .cbi-section{background:#202c3e!important;border-color:#3b506c!important;color:#e5edf9!important}
html[data-darkmode="true"] .cbi-section>legend,html.dark .cbi-section>legend,body.dark .cbi-section>legend{background:#2a3a52!important;color:#dbeafe!important}
html[data-darkmode="true"] .cbi-section .cbi-section-descr,html.dark .cbi-section .cbi-section-descr,body.dark .cbi-section .cbi-section-descr{color:#aebfd6!important}
html[data-darkmode="true"] .cbi-section .cbi-value,html.dark .cbi-section .cbi-value,body.dark .cbi-section .cbi-value{border-color:#34465f!important}
html[data-darkmode="true"] .cbi-section .cbi-value-title,html.dark .cbi-section .cbi-value-title,body.dark .cbi-section .cbi-value-title,html[data-darkmode="true"] .cbi-section .cbi-value-description,html.dark .cbi-section .cbi-value-description,body.dark .cbi-section .cbi-value-description,html[data-darkmode="true"] .cbi-section .cbi-value-field,html.dark .cbi-section .cbi-value-field,body.dark .cbi-section .cbi-value-field{color:#c7d7ec!important}
html[data-darkmode="true"] .cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),html.dark .cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),body.dark .cbi-section .cbi-value-field input:not([type=radio]):not([type=checkbox]),html[data-darkmode="true"] .cbi-section .cbi-value-field select,html.dark .cbi-section .cbi-value-field select,body.dark .cbi-section .cbi-value-field select,html[data-darkmode="true"] .cbi-section .cbi-value-field textarea,html.dark .cbi-section .cbi-value-field textarea,body.dark .cbi-section .cbi-value-field textarea{background:#27364a!important;color:#e5edf9!important;border-color:#465d7c!important}
html[data-darkmode="true"] .cbi-section .cbi-value-field ul li,html.dark .cbi-section .cbi-value-field ul li,body.dark .cbi-section .cbi-value-field ul li,html[data-darkmode="true"] .cbi-section .cbi-value-field label:has(input[type=radio]),html.dark .cbi-section .cbi-value-field label:has(input[type=radio]),body.dark .cbi-section .cbi-value-field label:has(input[type=radio]){color:#dbeafe!important;background:transparent!important}


/* 1.5.2：页面内容左右铺满主内容区，不保留主题 container 的窄版留白 */
.main .container:has(.hinfan-card){
  width:100%!important;
  max-width:none!important;
  margin-left:0!important;
  margin-right:0!important;
  padding-left:0!important;
  padding-right:0!important;
  box-sizing:border-box!important;
}
.main .container:has(.hinfan-card) .cbi-map,
.main .container:has(.hinfan-card) .hinfan-card,
.main .container:has(.hinfan-card) .cbi-section{
  width:100%!important;
  max-width:none!important;
  margin-left:0!important;
  margin-right:0!important;
  box-sizing:border-box!important;
}
</style>
]] .. (m.description or "")


-- ---------------- 1. 控制模式 ----------------

local s = m:section(TypedSection, "global", "控制模式",
	"选谁来决定风扇转速。除『自定义曲线』外都不需要用户态进程参与。")
s.anonymous = true
s.addremove = false

local o = s:option(ListValue, "mode", "风扇控制方式")
o.widget = "radio"
o.default = "kernel"
o:value("kernel", "内核温控（推荐）",
	"完全交给设备树 cooling-maps：45°C 起转、55/65/75°C 逐档加速，内核自己带 4°C 回差")
o:value("manual", "自定义曲线",
		"由调温大师守护进程按下面的曲线调速，关闭时会自动交还内核温控")
o:value("full", "全速运转",
	"风扇 255/255 常转，适合长时间压测或大文件传输")
o:value("off", "强制停转（谨慎）",
	"直接关闭 PWM 输出。此时内核设备树的过热保护对风扇失效，只剩 CPU 降频和 95°C 硬件复位")

-- ---------------- 2. 自定义曲线 ----------------

-- 独立的曲线/高级设置卡片：与顶部状态区、控制模式、设备树状态形成清晰分区。
local s2 = m:section(TypedSection, "global", "温度曲线与高级调节",
	"在这里编辑温度到 PWM 的控制曲线。只有选择「自定义曲线」时，这组曲线才会接管风扇。")
s2.anonymous = true
s2.addremove = false
local curve_heading = s2:option(DummyValue, "_curve_heading", "温度曲线与高级调节")
curve_heading.rawhtml = false
curve_heading.description = "设置曲线预设、温度/PWM 节点、采样周期、降档回差和降温步长。"


-- 预设和曲线在同一次 CBI 提交中按选项顺序写入：
-- 先由 preset.write 记录本次明确选择的预设，再由 curve.write 统一写最终曲线，
-- 避免后执行的 DynamicList 把预设曲线覆盖成提交前页面上的旧值。
local preset_to_apply = {}
local PRESETS = {
	quiet = {
		label = "静音优先",
		desc = "50°C 才起转，转速更保守，夜里几乎听不到",
		curve = "50:90 60:120 70:165 80:210",
		hyst = "6",
	},
	balanced = {
		label = "均衡（默认，同设备树）",
		desc = "45/55/65/75°C 四档，和内核温控的台阶一致",
		curve = "45:90 55:120 65:165 75:210",
		hyst = "4",
	},
	performance = {
		label = "散热优先",
		desc = "40°C 就起转并给到更高转速，适合密闭机箱",
		curve = "40:120 48:165 56:210 64:255",
		hyst = "3",
	},
}

local po = s2:option(ListValue, "preset", "一键预设",
	"选择任一预设后，保存时会用该预设整段替换曲线；选『保持当前曲线』则保留手工设置")
po.widget = "radio"
po.rmempty = false
po:value("keep", "保持当前曲线", "不套用预设，保留下面的手工曲线")
for k, v in pairs(PRESETS) do
	po:value(k, v.label, v.desc)
end
po.default = "keep"

function po.write(self, section, value)
	if value and PRESETS[value] then
		-- 预设在自己的 write 阶段直接落到 UCI，不能依赖 CBI 各选项 write 的调用顺序。
		-- DynamicList 可能先于本选项执行 write，若只记录标记，预设就会被旧曲线覆盖/丢失。
		local c = self.map.uci
		local entries = {}
		for entry in PRESETS[value].curve:gmatch("%S+") do
			entries[#entries + 1] = entry
		end
		c:set_list("hinlinkfan", section, "curve", entries)
		c:set("hinlinkfan", section, "hysteresis", PRESETS[value].hyst)
		c:set("hinlinkfan", section, "preset_applied", value)
		preset_to_apply[section] = value
	end
end

o = s2:option(DummyValue, "_applied", "当前曲线来源")
function o.cfgvalue(self, section)
	local v = self.map.uci:get("hinlinkfan", section, "preset_applied")
	if v and PRESETS[v] then
		return "已套用预设：" .. PRESETS[v].label .. "（下面曲线即该预设内容）"
	end
	return v and v ~= "" and ("已套用预设：" .. v) or "手工曲线"
end

o = s2:option(DynamicList, "curve", "温度 → 转速 阶梯",
	"格式 温度:转速，例如 45:90 表示 45°C 时 PWM 给到 90/255；最多 8 档")
o.placeholder = "45:90"
o.rmempty = false
o.optional = true

-- 自定义曲线统一由这里写入：预设优先；否则保存用户编辑的 DynamicList。
-- 若曲线内容发生变化，来源标记切换为 custom，避免页面误报仍来自旧预设。
function o.write(self, section, value)
	local c = self.map.uci
	local chosen = preset_to_apply[section]
	local entries = {}
	if chosen and PRESETS[chosen] then
		for entry in PRESETS[chosen].curve:gmatch("%S+") do
			entries[#entries + 1] = entry
		end
		c:set("hinlinkfan", section, "hysteresis", PRESETS[chosen].hyst)
		c:set("hinlinkfan", section, "preset_applied", chosen)
	else
		if type(value) == "table" then
			for _, entry in ipairs(value) do
				entry = tostring(entry or ""):match("^%s*(.-)%s*$")
				if entry ~= "" then entries[#entries + 1] = entry end
			end
		elseif value ~= nil then
			local entry = tostring(value):match("^%s*(.-)%s*$")
			if entry ~= "" then entries[1] = entry end
		end
		local old = c:get_list("hinlinkfan", section, "curve") or {}
		local changed = (#old ~= #entries)
		if not changed then
			for i, entry in ipairs(entries) do
				if old[i] ~= entry then changed = true; break end
			end
		end
		if changed then c:set("hinlinkfan", section, "preset_applied", "custom") end
	end
	c:set_list("hinlinkfan", section, "curve", entries)
	preset_to_apply[section] = nil
end
-- 不设 datatype：AbstractValue.transform 就是按 datatype 再校验一次的，
-- DynamicList 传进来的是一张表，datatype 报不过会**静默不保存**，这里用自己的 validate 管到底。
function o:validate(value)
	-- 成功必须返回原值（返回 nil 会被当成校验失败），失败返回 nil + 错误文案
	local items = type(value) == "table" and value or { value }
	local _, v, t, p
	for _, v in pairs(items) do
		v = tostring(v or "")
		if #v > 0 then
			t, p = v:match("^(%d+):(%d+)$")
			if not t then
				return nil, "每行格式应为 温度:转速（例如 45:90）"
			end
			t, p = tonumber(t), tonumber(p)
			if t < 20 or t > 110 then
				return nil, "温度请填 20 ~ 110（°C）"
			end
			if p < 0 or p > 255 then
				return nil, "转速请填 0 ~ 255"
			end
		end
	end
	return value
end

o = s2:option(Value, "tick", "采样周期（秒）",
	"默认 2 秒。改小响应更快但更耗电，改大更省电但响应迟钝")
o.datatype = "range(1,60)"
o.default = "2"

o = s2:option(Value, "hysteresis", "降档回差（°C）",
	"降温要低于档位阈值这么多才降档，避免转速在阈值上反复起停")
o.datatype = "range(0,20)"
o.default = "4"

o = s2:option(Value, "ramp", "降温步长",
	"每个采样周期最多降多少 PWM，升温是立即响应的；调小更平顺，调大更灵敏")
o.datatype = "range(1,255)"
o.default = "32"

-- 设备树 / 内核状态信息已整合进顶部「内核设备树温控」卡片。

m.on_commit = function()
	run("/etc/init.d/hinlinkfaninit restart >/dev/null 2>&1")
	-- 给守护进程一点时间落地新配置，让同一次请求里的状态卡片就是新值
	run("sleep 1")
end

return m
