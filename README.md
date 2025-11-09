<div align="center">
    <h1>悬浮时间</h1>

  <img src="./assets/home.jpg" alt="App 界面预览" width="45%" />
  <img src="./assets/PiP.jpg" alt="App 界面预览" width="45%" />
<br/>
</div>
<br/>

一个使用 Flutter 编写的轻量级应用，在 Android 上可将一个可拖动的时钟以悬浮窗形式显示在屏幕任意位置，支持多源时间同步与偏差显示。

**主要特性**

- 可在 0.1 秒与 0.01 秒显示精度间切换，并提供多种暗色高亮（默认暗红）用于渲染快速变化的小数位，兼容悬浮窗与画中画显示（例如 `12:34:56.7` / `12:34:56.78`）。
- 可在 Android 上以悬浮窗（Overlay）形式显示，可拖动、固定与关闭。
- 支持多时间源（System、NTP、HTTP 等），并展示与系统时间的偏差（ms）。
- 定期自动同步 NTP/HTTP 时间并保存最近同步记录。
- 支持本地持久化用户添加的时间源（`shared_preferences`）。
- 支持画中画模式（PiP）。
