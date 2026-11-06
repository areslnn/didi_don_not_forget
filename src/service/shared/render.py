"""Dependency-free HTML for a paired iPad or Kindle display.

Only summarized fields are rendered. Every external string passes through HTML
escaping; neither credentials nor arbitrary dictionary contents are serialized.
"""
from __future__ import annotations

import datetime as dt
from html import escape
import math
import time

TZ = dt.timezone(dt.timedelta(hours=8))
DASH = "—"


def _mapping(value):
    return value if isinstance(value, dict) else {}


def _list(value):
    return value if isinstance(value, list) else []


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        return value if math.isfinite(value) else None
    except OverflowError:
        return None


def _text(value, default=DASH):
    if value is None or value == "":
        return escape(default, quote=True)
    return escape(str(value), quote=True)


def _fmt(value, digits=0):
    value = _number(value)
    return format(value, f",.{digits}f") if value is not None else DASH


def _stamp(value):
    try:
        if _number(value) is not None:
            return dt.datetime.fromtimestamp(value, TZ)
        if isinstance(value, str):
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed.astimezone(TZ) if parsed.tzinfo is not None else None
    except (ValueError, OverflowError, OSError):
        pass
    return None


def _date(value, full=False):
    date = _stamp(value)
    return date.strftime("%Y/%m/%d %H:%M" if full else "%m/%d %H:%M") if date else DASH


def _age(value, now):
    date = _stamp(value)
    return now - date.timestamp() if date else None


def _source_line(value, now, category):
    updated = value.get("updatedAt")
    age = _age(updated, now)
    status = value.get("status")
    max_age = 60 if category == "system" else 360
    if category == "system":
        state = "已同步" if age is not None and -60 <= age <= max_age else "未同步" if age is None else "显示上次读数"
    elif status == "live" and age is not None and -60 <= age <= max_age:
        state = "已同步"
    else:
        state = "显示上次读数" if age is not None else "未连接"
    stale = state != "已同步"
    return '<p class="source-line' + (' stale' if stale else '') + '">' + _text(state) + ' · 数据时间 ' + _text(_date(updated)) + '</p>'


def _meter(value, label):
    value = _number(value)
    if value is None:
        return '<div class="meter missing" aria-label="' + _text(label + "未提供") + '"><span></span></div>'
    value = max(0, min(100, value))
    return ('<div class="meter" role="meter" aria-label="' + _text(label) + '" aria-valuemin="0" aria-valuemax="100" '
            'aria-valuenow="' + str(value) + '"><span style="width:' + str(value) + '%"></span></div>')


def _metric(title, subtitle, label, value, unit, percent, details):
    rows = ''.join('<div class="metric-detail"><span>' + _text(k) + '</span><strong>' + _text(v) + '</strong></div>' for k, v in details)
    return ('<section class="metric"><h3>' + _text(title) + '</h3><p class="subtle device">' + _text(subtitle) + '</p>'
            '<p class="metric-label">' + _text(label) + '</p><p class="metric-value">' + _text(value) + '<span class="unit">' + _text(unit, '') + '</span></p>'
            + _meter(percent, title + label) + '<div class="metric-details">' + rows + '</div></section>')


def _system(value, now):
    cpu, memory, disk, battery, gpu = (_mapping(value.get(k)) for k in ("cpu", "memory", "disk", "battery", "gpu"))
    cpu_usage = _number(cpu.get("usagePercent"))
    memory_used, memory_total = _number(memory.get("usedBytes")), _number(memory.get("totalBytes"))
    disk_used, disk_total = _number(disk.get("usedBytes")), _number(disk.get("totalBytes"))
    memory_percent = memory_used / memory_total * 100 if memory_used is not None and memory_total and memory_total > 0 else None
    disk_percent = disk_used / disk_total * 100 if disk_used is not None and disk_total and disk_total > 0 else None
    disk_free = disk_total - disk_used if disk_total is not None and disk_used is not None else None
    gib = lambda v, n=1: _fmt(v / (1024 ** 3), n) if v is not None else DASH
    cores = _number(cpu.get("cores"))
    raw_pressure = memory.get("pressure") if isinstance(memory.get("pressure"), str) else None
    pressure = {"normal": "正常", "warning": "偏高", "critical": "较高"}.get(raw_pressure, raw_pressure or "未提供")
    cpu_html = _metric("CPU 处理器", cpu.get("name"), "使用率", _fmt(cpu_usage), "%", cpu_usage,
                       [("核心数量", f"{_fmt(cores)} 核" if cores is not None else DASH), ("图形处理器", gpu.get("name"))])
    memory_html = _metric("系统内存", "已用 / 总量", "已用", gib(memory_used), "GB", memory_percent,
                          [("总量", gib(memory_total) + " GB" if memory_total is not None else DASH), ("内存压力", pressure)])
    disk_html = _metric("存储空间", "Mac 启动磁盘", "可用", gib(disk_free, 0), "GB", disk_percent,
                        [("已用 / 总量", f"{gib(disk_used, 0)} / {gib(disk_total, 0)} GB" if disk_used is not None and disk_total is not None else DASH),
                         ("磁盘占用", _fmt(disk_percent) + "%" if disk_percent is not None else DASH)])
    charge = _number(battery.get("percent"))
    if battery.get("present") is False:
        power_name, power_label, power_value, power_unit = "台式 Mac · 交流供电", "供电状态", "外接", "电源"
        charge = None
    elif battery.get("present") is True:
        power_name = "正在充电" if battery.get("charging") is True else "已连接电源" if battery.get("onAC") is True else "使用电池供电" if battery.get("onAC") is False else "电源状态未提供"
        power_label, power_value, power_unit = "电池电量", _fmt(charge), "%"
    else:
        power_name, power_label, power_value, power_unit = "电源状态未提供", "电池电量", DASH, "%"
        charge = None
    uptime = _number(value.get("uptimeSeconds"))
    uptime_text = f"{int(uptime // 86400)} 天 {int(uptime % 86400 // 3600)} 小时" if uptime is not None else DASH
    power_html = _metric("电源与运行", power_name, power_label, power_value, power_unit, charge,
                         [("连续运行", uptime_text), ("本机采样", _date(value.get("updatedAt")))])
    return ('<section class="system-section"><div class="section-heading"><h2><span class="section-no">01</span> 这台 Mac</h2>'
            '<span class="subtle">本机状态</span></div>' + _source_line(value, now, "system") +
            '<table class="metrics-layout" role="presentation"><tbody><tr><td>' + cpu_html + '</td><td>' + memory_html + '</td></tr>'
            '<tr><td>' + disk_html + '</td><td>' + power_html + '</td></tr></tbody></table></section>')


def _account(value, now):
    parts = ['<section class="account-section"><div class="section-heading"><h2><span class="section-no">02</span> Codex 账号额度</h2></div>',
             _source_line(value, now, "account")]
    windows = _list(value.get("windows"))
    if not windows:
        parts.append('<div class="quota-window"><p class="metric-label">剩余额度</p><p class="quota-value">—</p><p class="subtle">暂未读取到账号额度</p></div>')
    for window in windows:
        window = _mapping(window)
        remain, used = _number(window.get("remainingPercent")), _number(window.get("usedPercent"))
        label = window.get("label") or "账号额度"
        parts.append('<div class="quota-window"><p class="metric-label">' + _text(label) + ' · 剩余</p>'
                     '<p class="quota-value">' + _fmt(remain) + '<span class="unit">%</span></p>' + _meter(remain, str(label) + "剩余") +
                     '<p class="quota-detail">已用 ' + (_fmt(used) + '%' if used is not None else DASH) + '</p>'
                     '<p class="quota-detail">下次重置 ' + _text(_date(window.get("resetsAt"))) + '</p></div>')
    parts.append('<p class="scope-note">ChatGPT 账号下的 Codex 额度</p>')
    if value.get("error"):
        parts.append('<p class="notice">' + _text(value.get("error")) + '</p>')
    reset = _mapping(value.get("resetCredits"))
    count = _number(reset.get("availableCount"))
    parts.append('<div class="reset-section"><div class="reset-heading"><h3>重置卡</h3><span>' +
                 (_fmt(count) + ' 张可用' if count is not None else '数量未提供') + '</span></div><p class="reset-caption">有效期至 · 北京时间</p><ul class="reset-list">')
    credits = [v for v in _list(reset.get("credits")) if isinstance(v, dict) and v.get("status") == "available"]
    credits.sort(key=lambda row: _number(row.get("expiresAt")) if _number(row.get("expiresAt")) is not None else float("inf"))
    for i, card in enumerate(credits, 1):
        expiry = _number(card.get("expiresAt"))
        remaining = expiry - now if expiry is not None else None
        label = "卡片已到期" if remaining is not None and remaining <= 0 else "3天内到期" if remaining is not None and remaining <= 259200 else ""
        parts.append('<li' + (' class="expiring"' if label else '') + '><span class="card-no">' + f'{i:02d}' + '</span><span class="card-date">' +
                     (_text(_date(expiry)) if expiry is not None else '到期时间未提供') + '</span>' +
                     ('<strong class="expiry-label">' + label + '</strong>' if label else '') + '</li>')
    if not credits:
        parts.append('<li class="subtle">' + ('暂无可用重置卡' if count == 0 else '卡片详情未提供') + '</li>')
    parts.append('</ul><p class="scope-note">仅展示，不会使用重置卡</p></div></section>')
    return ''.join(parts)


def _starsg(value, now):
    entries = _list(value.get("entries"))
    amounts = [_number(_mapping(entry).get("amountUSD")) for entry in entries]
    total = sum(amounts) if entries and all(v is not None for v in amounts) else 0 if value.get("status") == "live" and isinstance(value.get("entries"), list) and not entries else None
    parts = ['<section class="starsg-section"><div class="section-heading"><h2><span class="section-no">03</span> Starsg 用量</h2><span class="subtle">',
             _text(value.get("periodLabel"), "最近30天"), '</span></div>', _source_line(value, now, "starsg"),
             '<div class="starsg-summary"><span>总费用</span><strong><span class="currency">$</span>' + _fmt(total, 2) + '</strong><span class="subtle">USD</span></div>']
    if value.get("error"):
        parts.append('<p class="notice">' + _text(value.get("error")) + '</p>')
    parts.append('<div class="table-wrap"><table class="usage-table"><thead><tr><th scope="col">Key 名称</th><th scope="col" class="numeric">调用次数</th>'
                 '<th scope="col" class="numeric">费用 / USD</th><th scope="col" class="numeric">费用占比</th></tr></thead><tbody>')
    for entry in entries:
        entry = _mapping(entry)
        share = _number(entry.get("sharePercent"))
        parts.append('<tr><th scope="row">' + _text(entry.get("name")) + '</th><td class="numeric">' + _fmt(entry.get("calls")) +
                     '</td><td class="numeric amount">' + _fmt(entry.get("amountUSD"), 6) + '</td><td class="numeric">' +
                     (_fmt(share, 2) + '%' if share is not None else DASH) + '</td></tr>')
    if not entries:
        parts.append('<tr><td colspan="4" class="empty-state">' + ('当前周期暂无用量' if total == 0 else '尚未连接 · 请在 Mac 组件连接 Starsg') + '</td></tr>')
    parts.append('</tbody></table></div><p class="scope-note">显示 Key 名称与用量汇总，密钥不会出现在此页面。</p></section>')
    return ''.join(parts)


def render_page(data, mode="display"):
    """Render a complete page; ``kindle`` deliberately contains no JavaScript."""
    data = _mapping(data)
    mode = "kindle" if mode == "kindle" else "display"
    account, system, starsg = (_mapping(data.get(k)) for k in ("account", "system", "starsg"))
    now = time.time()
    date = dt.datetime.fromtimestamp(now, TZ)
    weekday = ("星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日")[date.weekday()]
    refresh = 300 if mode == "kindle" else 60
    date_text = f'{date.year} 年 {date.month} 月 {date.day} 日 · {weekday}'
    route = "/kindle" if mode == "kindle" else "/display"
    extra = '<a href="/display">普通版</a>' if mode == "kindle" else '<a href="/kindle">墨水屏版</a><button type="button" id="fullscreen" hidden>全屏</button>'
    script = '' if mode == "kindle" else '<script src="/display.js" defer></script>'
    demo = '<p class="demo-banner">示例数据 · 非真实账号</p>' if data.get("demo") is True else ''
    return ('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta http-equiv="refresh" content="' + str(refresh) + '"><meta name="color-scheme" content="light">'
            '<title>桌面看板 · AI & Mac</title><link rel="stylesheet" href="/display.css">' + script + '</head>'
            '<body class="' + mode + '"><div class="workspace"><nav class="toolbar" aria-label="看板操作"><span class="toolbar-label">PERSONAL DASHBOARD</span>'
            '<span class="toolbar-actions"><a id="refresh" href="' + route + '">刷新</a>' + extra + '</span></nav>'
            '<main id="dashboard" class="paper">' + demo + '<header class="masthead"><div><p class="eyebrow">YOUR MAC. YOUR WORKSPACE.</p><h1>桌面看板</h1></div>'
            '<div class="header-date"><p class="date-label">' + _text(date_text) + '</p><p class="subtle">北京时间 · 画面每 ' + str(refresh // 60) + ' 分钟刷新</p></div></header>'
            '<div class="dashboard-layout"><div class="machine-column">' + _system(system, now) + '</div><aside class="account-column">' + _account(account, now) + '</aside></div>'
            + _starsg(starsg, now) + '<footer class="paper-footer"><p>电脑采样 10 秒 · 额度同步 5 分钟</p><p>局域网只读看板 · 数据时间见各区域</p></footer></main>'
            '<p class="page-caption">少一点干扰，多一点专注。</p><p class="attribution">基于 <a href="https://github.com/areslnn/didi_don_not_forget" rel="noreferrer">areslnn / didi_don_not_forget</a></p></div></body></html>')
