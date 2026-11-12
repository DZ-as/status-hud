# 会话状态悬浮条（Session Status HUD）

屏幕最上沿一条细线，一个会话一段；鼠标扫到顶部就展开全部会话的明细，移开自动收起。不占地方、不进 Alt+Tab、不抢焦点。

![收起状态](hud-bar.png)

## 安装（Windows）

需要 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 和系统自带的 Windows PowerShell 5.1。

```powershell
git clone https://github.com/DZ-as/status-hud.git D:\plugins\status-hud
```

然后在 DSH 里让 agent 执行（路径换成你的克隆位置）：

```
plugin_manager action=install_bundle target="D:\plugins\status-hud"
```

最后**完全重启 DSH 一次**——面板那半边（`client.js`，负责点击跳转）只在启动时进模块图，不重启跳转不生效。

装完屏幕顶部会出现一条细线，跑一个会话它就会多一段。

**升级**：`git pull` 后重启 DSH 即可（`hud.ps1` 的改动只要结束悬浮条进程，插件 2 秒内会自动重启它）。
**卸载**：`plugin_manager action=remove_bundle target="@local/session-status-hud"`，再删掉 `%LOCALAPPDATA%\dsh-status-hud\`。

## 平台说明

- **仅 Windows**：渲染层是 PowerShell 5.1 + WPF，通知用 WinRT toast。macOS/Linux 需要重写 `hud.ps1`（Host 半边可复用）。
- 插件会拉起一个 PowerShell 进程绘制悬浮条，并在 `127.0.0.1` 上注册三条本地 HTTP 路由（供点击/移除使用），不对外网开放。
- 运行时状态（快照、顺序、日志）写在 `%LOCALAPPDATA%\dsh-status-hud\`，不会写进 DSH 安装目录。

## 怎么用

| 动作 | 效果 |
| --- | --- |
| 鼠标甩到屏幕最上沿（细条上方 **4px 内**） | 立即展开：面板下滑 10px 落位（130ms） |
| 鼠标移开 | 200ms 后向上滑走，收回顶部细线（150ms） |
| 面板里按住拖动 | 横向滚动会话列（窗口不抢焦点，滚轮消息到不了它） |
| **单击某个会话列** | 切到那个会话，并把 DSH 窗口置前 |
| 悬停某个会话列 | 该列高亮、其余列变暗，**上方对应那一段细条向下探出 10px** |
| **按住右键 650ms** | 把这一列从条上移除：按住时卡片内容模糊、中间出现垃圾桶图标，外面一圈红色进度条随按住时间填满；松手前不生效，它下一次开始新任务会自动回来 |
| 完成 / 出错 | 面板自动展开 2.5 秒，对应会话那一列弹跳一下（560ms），可以直接点进去 |
| 需要你确认 | 面板自动展开并一直停着，直到你处理 |
| 有程序全屏（游戏/视频） | 悬浮条整体隐藏，退出全屏后自动回到原位 |

![展开面板](hud-panel.png)

## 游戏模式

有程序**全屏**（独占全屏的游戏，或无边框全屏的播放器）时，悬浮条会整体隐藏，退出全屏后自动回到顶部。

判定方式（`hud.ps1` 里的 `HudStatus.Native.CheckFullscreen`）：

1. 取前台窗口的矩形，和它所在显示器的矩形比较——完全覆盖才算全屏；
2. 边界情况用 `SHQueryUserNotificationState` 辅助（`QUNS_RUNNING_D3D_FULL_SCREEN`）；
3. 如果全屏的正是 DSH 自己（进程名含 `Harness`），**不隐藏**——你在 DSH 里全屏阅读时仍然能看到状态条。

隐藏方式是**把窗口移到屏幕外**（`Top = -30000`），不是设 `Visibility`：后者会让 WPF 的 `ShowDialog` 返回、整个 HUD 进程退出。隐藏期间渲染和悬停判定都跳过，不占 CPU。

不需要这个行为的话，在 `cordis.patch.yml` 里加 `gameMode: false` 即可（默认 `true`）。

按住右键时的样子：

![按住右键](hud-hold.png)

## 长条：一个会话一段

会话 N 个就分成 N 段，段色就是那个会话的状态。**段间距恒定 190px**（等于列宽），收起和展开时位置完全不变，不会出现"一展开就摊开"的跳变。

| 颜色 | 含义 |
| --- | --- |
| 蓝 `#4C8DFF` | 运行中 |
| 琥珀 `#F5A524` | 等你回答/审批（半透明呼吸） |
| 绿 `#22C55E` | 已完成 |
| 红 `#EF4444` | 出错 |
| 灰 `#64748B` | 空闲 |

## 展开后每个会话一列

一列 = 一个会话，列宽 190px，与上方细条按序号一一对应：

- **会话标题**（不是工作区目录名；标题由模型异步生成，还没生成时显示"新会话 XXXX"，并每 15 秒重试取值，直到拿到为止）
- 工作区名（小字）
- 状态 + 用时（运行中「已跑 1:12」，完成「用时 2:41」）
- 当前动作（调用的工具 + 参数摘要）
- 第几轮 / 几步 / 多少次工具 / 子代理数（从会话日志折叠，重启插件也不丢）

**成员规则**：**用过的会话才上条，上条之后就一直保留**。没在用的历史会话不会出现；某个会话第一次产生活动（或你打开它、它跑了一轮）时加入，之后即使关掉、重启 DSH 也还在（记录在 `order.json`）。每个会话的日志会被折叠一次，所以"已完成 用时 2:41 / 第 34 轮 · 389 步"这些数字对重新载入的会话同样成立——完成的会话留在列表里变暗，只有被更新的会话挤出、被归档删除、或被你在列上右键长按移除时才消失。**顺序固定**按进入先后，状态变化不会让列跳动。

**顺序会记住**：`%LOCALAPPDATA%\dsh-status-hud\order.json` 保存 `会话ID → 顺序` 和手动移除记录，重启 DSH 后列的排列不变。

## 展开与点击

- **悬停立即展开**（不做停留判定）：热区是屏幕最上沿 **4px** 的极窄条带（横向为细条宽度），光标怼到顶边才触发，平时在顶部附近移动不会误碰
- 收起状态下窗口是 `WS_EX_TRANSPARENT`：**点击直接落到下面的浏览器**，不会被悬浮条吃掉；展开时才恢复可点
- 之前的"停留 300ms + 热区只留 10px"两道防线已经关掉（觉得太钝），需要的话把 `$DWELL_MS` 改回 300、`$HOT_H` 改成 12 即可

## 通知

默认**不发** Windows 通知，改成上面那条自动弹出。想恢复系统通知就把 `notifications` 改成 `true`。

## 配置（`cordis.patch.yml` 里的 `config`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `hud` | `true` | 是否启用悬浮条 |
| `notifications` | `false` | 是否额外发 Windows 通知 |
| `autoShowMs` | `4000` | 完成/出错时自动展开停留多久（等你确认不受此限） |
| `eventLingerMs` | `8000` | 事件横条在面板里保留多久 |
| `notifyDone` / `notifyError` / `notifyWaiting` | `true` | 通知类别（`notifications` 打开后生效） |
| `minNotifyMs` | `8000` | 短于该时长的任务不弹完成通知 |
| `finishedLingerMs` | `120000` | 完成态在条上保留多久 |
| `idleResetMs` | `90000` | 多久没有新事件就判定为已停止 |
| `position` | `top-center` | `top-center` / `top-left` / `top-right` / `bottom-left` / `bottom-right` |
| `appId` | `com.deepseek.dsh` | 通知使用的应用身份 |
| `sound` | `false` | 通知是否带提示音 |
| `dataDir` | `%LOCALAPPDATA%\dsh-status-hud` | 状态快照与日志目录 |

## 文件

| 文件 | 作用 |
| --- | --- |
| `index.js` | Host 插件：把会话事件折成快照（`status.json` v3）、拉起悬浮窗、发通知 |
| `hud.ps1` | WPF 分段长条 + 会话列表（tool window，不进 Alt+Tab/任务栏） |
| `client.js` | 页面内半身：轮询点击请求并执行 `uiWorkspace.openSession()` |
| `notify.ps1` | Windows 通知（WinRT toast，无第三方依赖） |

## 实现要点

- 热区是 `y < 4` 的极窄条带：鼠标甩到屏幕上沿时会被系统钉在 y=0，必中；停在 y=10 附近则不会触发
- 悬停每 100ms 采样「光标坐标是否落在窗口矩形内」，不依赖 WPF 的 `IsMouseOver`
- 窗口是逐像素透明的分层窗口，**只对位移做动画、不做透明度动画**——后者会叠出半透明残影。展开是下滑落位（130ms），收起是整块向上滑出屏幕边缘（150ms，缓入加速）
- `hud.ps1` 保持纯 ASCII，中文文案全部由 Host 的 `status.json` 提供：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 GBK 读，脚本里写中文会直接解析失败

## 排查

- 单击会话没反应：先确认页面加载过本插件的客户端半身（它只在页面启动时注册，装完插件需要重启一次 DSH）
- 长条不出现：看 `%LOCALAPPDATA%\dsh-status-hud\dsh-status-hud.log` 与 `hud.log`
- 面板不展开：确认鼠标落在屏幕上沿；改了 `position` 要重启插件
- 想彻底停掉：在插件页禁用这个 bundle
