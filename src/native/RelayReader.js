/* Reads only rendered controls and the API-Key statistics card. No network,
   cookies, localStorage, framework state, or hidden data are accessed. */
((configuration) => {
  "use strict";
  const compact = value => String(value || "").replace(/\s+/g, "").trim();
  const title = "按APIKey调用次数";
  const periodTitle = compact(configuration.periodLabel);
  const callPattern = /([\d,]+)\s*次\s*调用/g;
  const moneyPattern = /\$\s*([\d,]+(?:\.\d{1,8})?)/g;
  const sharePattern = /(\d+(?:\.\d+)?)\s*%/g;
  function visible(element) {
    if (!element || !element.getClientRects().length || element.closest('[hidden],[aria-hidden="true"]')) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse" && style.opacity !== "0";
  }
  function text(element) {
    if (!visible(element)) return "";
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const parts = [];
    let node;
    while ((node = walker.nextNode())) {
      if (visible(node.parentElement) && node.nodeValue.trim()) parts.push(node.nodeValue.trim());
    }
    return parts.join("\n");
  }
  function correctPage() {
    const url = new URL(location.href), expected = new URL(configuration.usageURL);
    return url.protocol === "https:" && !url.username && !url.password && !url.hash &&
      url.origin === expected.origin && url.pathname === expected.pathname && url.search === expected.search;
  }
  function selectedPeriod() {
    for (const select of document.querySelectorAll("select")) {
      if (!visible(select)) continue;
      const matchingOption = [...select.options].find(option => compact(option.label) === periodTitle);
      if (matchingOption) return {element: select, option: matchingOption,
        correct: compact(select.selectedOptions[0]?.label) === periodTitle, type: "select"};
    }
    const controls = [...document.querySelectorAll('[role="combobox"],button[aria-haspopup="listbox"]')].filter(visible);
    const control = controls.find(el => compact(text(el)) === periodTitle) || controls.find(el => compact(el.getAttribute("aria-label")) === "时间范围");
    if (control) return {element: control, correct: compact(text(control)) === periodTitle, type: "custom"};
    return null;
  }
  function statsTab() {
    return [...document.querySelectorAll('[role="tab"]')].find(el => visible(el) && compact(text(el)) === "用量统计");
  }
  function prepare() {
    if (!correctPage()) return {action: "none", reason: "wrong_page"};
    const period = selectedPeriod();
    if (!period) return {action: "none", reason: "period_control_missing"};
    if (!period.correct) {
      if (period.element.disabled || period.element.getAttribute("aria-disabled") === "true") return {action: "none", reason: "loading"};
      if (period.type === "select") {
        const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value").set;
        setter.call(period.element, period.option.value);
        period.element.dispatchEvent(new Event("change", {bubbles: true}));
        return {action: "selected_period"};
      }
      const option = [...document.querySelectorAll('[role="option"]')].find(el => visible(el) && compact(text(el)) === periodTitle);
      if (option) { option.click(); return {action: "selected_period"}; }
      if (period.element.getAttribute("aria-expanded") !== "true") {
        period.element.click(); return {action: "opened_period_picker"};
      }
      return {action: "none", reason: "period_option_missing"};
    }
    const tab = statsTab();
    if (!tab) return {action: "none", reason: "stats_tab_missing"};
    if (tab.getAttribute("aria-selected") !== "true") {
      if (tab.getAttribute("aria-disabled") === "true") return {action: "none", reason: "loading"};
      tab.click(); return {action: "selected_statistics"};
    }
    return {action: "none", reason: "ready_to_read"};
  }
  function read() {
    if (!correctPage()) return {status: "wrong_page", reason: "需要打开模型服务用量页"};
    const period = selectedPeriod();
    if (!period?.correct) return {status: "not_ready", reason: "请将时间范围设为配置的统计周期"};
    const tab = statsTab();
    if (!tab || tab.getAttribute("aria-selected") !== "true") return {status: "not_ready", reason: "请切换到用量统计"};
    // A loading indicator or disabled Refresh button means the old graph must not be relabelled fresh.
    const loading = [...document.querySelectorAll('[aria-busy="true"],[role="progressbar"],button')].some(el =>
      visible(el) && (el.getAttribute("aria-busy") === "true" ||
        (el.getAttribute("role") === "progressbar" && el.getAttribute("aria-valuenow") === null) ||
        (el.tagName === "BUTTON" && compact(text(el)) === "刷新" && (el.disabled || el.getAttribute("aria-disabled") === "true"))));
    if (loading) return {status: "loading", reason: "平台正在加载统计"};
    const headings = [...document.querySelectorAll('h1,h2,h3,h4,[role="heading"]')].filter(visible);
    const heading = headings.find(el => compact(text(el)) === title);
    if (!heading) return {status: "not_ready", reason: "暂未找到按APIKey统计卡片"};
    let card = null;
    for (let el = heading.parentElement, depth = 0; el && depth < 6; el = el.parentElement, depth++) {
      if (el === document.body || el === document.documentElement) break;
      const otherHeading = [...el.querySelectorAll('h1,h2,h3,h4,[role="heading"]')].some(h => visible(h) && compact(text(h)) !== title);
      if (otherHeading) break;
      const value = text(el);
      if ([...value.matchAll(callPattern)].length || /暂无(?:数据|调用|记录)/.test(compact(value))) { card = el; break; }
    }
    if (!card) return {status: "not_ready", reason: "统计卡片尚未返回记录"};
    const cardText = text(card);
    if (/加载中|正在加载|加载失败|请求失败|出错|重试/.test(cardText)) return {status: "loading", reason: "统计卡片尚未就绪"};
    const counts = [...card.querySelectorAll("*")].filter(el => {
      if (!visible(el) || !/^[\d,]+\s*次\s*调用$/.test(text(el).trim())) return false;
      return ![...el.children].some(child => visible(child) && /^[\d,]+\s*次\s*调用$/.test(text(child).trim()));
    });
    const entries = [], seen = new Set();
    for (const count of counts) {
      let row = null;
      for (let el = count.parentElement; el && card.contains(el); el = el.parentElement) {
        const value = text(el);
        const calls = [...value.matchAll(callPattern)], money = [...value.matchAll(moneyPattern)], shares = [...value.matchAll(sharePattern)];
        if (calls.length > 1) break;
        if (calls.length === 1 && money.length === 1 && shares.length === 1) { row = {el, value, calls, money, shares}; break; }
        if (el === card) break;
      }
      if (!row || seen.has(row.el)) return {status: "invalid", reason: "APIKey记录不完整，保留上次读数"};
      seen.add(row.el);
      const name = row.value.replace(callPattern, "").replace(moneyPattern, "").replace(sharePattern, "").replace(/\s+/g, " ").trim();
      const calls = Number(row.calls[0][1].replace(/,/g, ""));
      const amountUSD = Number(row.money[0][1].replace(/,/g, ""));
      const reportedShare = Number(row.shares[0][1]);
      if (!name || name.length > 120 || compact(name).includes(title) || !Number.isSafeInteger(calls) || calls < 0 ||
          !Number.isFinite(amountUSD) || amountUSD < 0 || !Number.isFinite(reportedShare) || reportedShare < 0 || reportedShare > 100) {
        return {status: "invalid", reason: "统计值未通过校验"};
      }
      entries.push({name, calls, amountUSD, inputTokens: null, outputTokens: null, totalTokens: null, reportedShare});
    }
    const visibleCount = [...cardText.matchAll(callPattern)].length;
    if (entries.length !== visibleCount || entries.length > 1000) return {status: "invalid", reason: "统计行数未通过校验"};
    if (!entries.length) {
      if (!/暂无(?:数据|调用|记录)/.test(compact(cardText))) return {status: "not_ready", reason: "统计记录尚未加载"};
      return {status: "ready", periodLabel: configuration.periodLabel, entries: [], emptyConfirmed: true};
    }
    const total = entries.reduce((sum, entry) => sum + entry.amountUSD, 0);
    const totalCalls = entries.reduce((sum, entry) => sum + entry.calls, 0);
    if (!Number.isFinite(total) || !Number.isSafeInteger(totalCalls)) return {status: "invalid", reason: "汇总值超出有效范围"};
    for (const entry of entries) {
      const sharePercent = total > 0 ? 100 * entry.amountUSD / total : 0;
      if (Math.abs(entry.reportedShare - sharePercent) > 0.11) return {status: "invalid", reason: "费用占比与金额不符，保留上次读数"};
      entry.sharePercent = total > 0 ? Math.round(sharePercent * 10) / 10 : null;
      delete entry.reportedShare;
    }
    return {status: "ready", periodLabel: configuration.periodLabel, entries, emptyConfirmed: false};
  }
  return {prepare, read};
})
