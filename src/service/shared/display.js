/* Progressive enhancement only. All values and refresh work without scripts. */
'use strict';
(function () {
  var button = document.getElementById('fullscreen');
  if (!button || !document.documentElement.requestFullscreen) return;
  button.hidden = false;
  button.addEventListener('click', function () {
    var request = document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen();
    if (request && request.catch) request.catch(function () {
      button.textContent = '请使用浏览器全屏';
      button.disabled = true;
    });
  });
  document.addEventListener('fullscreenchange', function () {
    button.textContent = document.fullscreenElement ? '退出全屏' : '全屏';
  });
}());
