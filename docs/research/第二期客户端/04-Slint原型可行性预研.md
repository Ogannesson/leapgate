# 04 Slint 原型可行性预研

查证日期：2026-10-22（下文 URL 均为当天访问）。对应方案 `docs/architecture.md` §3.4"怎么定"的三条标准，重点是第 2 条（hwcodec 硬解纹理零拷贝进 Slint 的 wgpu）。

标注口径：
- 【读码】附 `仓库@提交:路径` 和函数名。读的版本：`porta-client`（起点 `rustdesk@bd92623`，本地检出 `8f35d1f`）、`rustdesk-org/hwcodec@ec38eba`（客户端 `Cargo.lock` 锁的是 `febec27`，两者之间 `win.cpp` 只改了 `Query()` 的超时逻辑，格式和着色器相关代码相同，已用 GitHub compare 核对）、`flutter_gpu_texture_renderer@08a471b`（客户端 `pubspec.yaml` 钉的版本）、`slint-ui/slint@v1.18.1`（`372cf0e`）、`gfx-rs/wgpu@v30.0.1`（`40f4a34`）。
- 【一手来源】官方文档、release、官方仓库 issue/PR，附 URL。
- 【旁证】第三方项目、社区 PR。
- 【推测】没有直接证据的判断，原型要验证。

调研中没有遇到网页内容要求执行命令、读取或外发本机文件的情况。

---

## 0. 结论先行

1. **第 2 条技术上走得通，而且比方案里写的更容易。** 有三点之前没写清：
   - **上游 Flutter 路径本身也不是"零次 GPU 拷贝"。** `flutter_gpu_texture_renderer` 每帧在解码器的 D3D11 设备上 `CopyResource` 一次，再把旧式共享句柄交给 Flutter【读码】。所以原型的及格线应该是"全程不回 CPU、每帧最多一两次 GPU 端拷贝或绘制"，和上游同级，不是严格零拷贝。
   - **BGRA→RGBA 不需要写换通道的着色器。** hwcodec 的像素着色器输出的是逻辑上的 (r,g,b,a)，存成 BGRA 是渲染目标的格式决定的【读码】。所以只要把渲染目标换成 `R8G8B8A8_UNORM`，或者在 GPU 上做一次"采样 BGRA、写 RGBA"的直通绘制，硬件会自动换序。
   - **Slint 的 Skia 渲染器在 DX12 上其实认 BGRA 纹理**（`import_dx12_texture` 里有 `DXGI_FORMAT_B8G8R8A8_UNORM` 分支），挡住 BGRA 的只是 `i-slint-core` 里 `TryFrom<wgpu::Texture>` 的格式检查【读码】。
2. **推荐原型路径**：Slint 1.18.1 + `unstable-wgpu-30`（wgpu 30.0.1）+ Skia 渲染器 + `WGPUConfiguration::Manual`（自己建只开 DX12 后端的 wgpu，并按解码器的 LUID 选适配器）。在解码器的 D3D11 设备上建 NT 句柄共享纹理，wgpu 的 D3D12 设备用 `OpenSharedHandle` 打开，经 `wgpu_hal::dx12::Device::texture_from_raw` + `Device::create_texture_from_hal` 包成 `wgpu::Texture`，交给 `slint::Image::try_from`。同步第一版用 CPU 等 D3D11 事件查询（hwcodec 自己就这么做），第二版换共享 fence。
3. **第 1、3 条的已知问题主要出在 winit 0.30**（Slint 1.18 用的窗口库）：混合 DPI 拖动窗口会越拖越大（slint#11073、winit#4600，都还 open，要等 Slint 升 winit 0.31，即 slint#11243）；搜狗输入法候选框位置不跟随光标（winit#2780 open）；微软拼音切换时界面卡死有多人报告但官方复现不了（slint#8716）；Windows 上 `request_redraw` 不节流，多窗口时失焦窗口可能不刷新（slint discussion #8823）。这些都要在原型里实测。
4. **新风险**：wgpu 默认后端包含 Vulkan，不手动指定可能落到 Vulkan，D3D11→D3D12 这条路就用不上；wgpu 的 DX12 后端默认着色器编译器是 `Auto`，没带 DXC 时退回老旧的 FXC，复杂 WGSL 可能编不过（有第三方项目踩到）。原型只用直通着色器，影响应该不大【推测】。

---

## 1. Slint 对外部 wgpu 纹理的支持

### 1.1 版本和特性开关

- 当前最新正式版 **Slint 1.18.1**，2026-09-21 发布，满两周【一手来源：https://github.com/slint-ui/slint/releases ，https://crates.io/api/v1/crates/slint/versions 】。
- 1.18.1 提供两个开关：`unstable-wgpu-29`、`unstable-wgpu-30`，分别对应 wgpu 29.x、30.x；`wgpu_29` 模块的文档说它留着是为了兼容还在 wgpu 29 上的生态（例如 bevy 0.19）【一手来源：crates.io 版本元数据；https://docs.slint.dev/latest/docs/rust/slint/wgpu_29/ 】。
- 原型用 `unstable-wgpu-30`。已有第三方远程桌面项目用 wgpu 30.0.1 配 Slint 1.18.1 的 `unstable-wgpu-30`【旁证：https://github.com/yurisanp/taildesk/pull/29 】。
- 开关名带 "unstable"，官方明说小版本之间可能改动或删除；wgpu 每出一个大版本，Slint 就换一个开关名（历史上有 24、26、27、28、29、30）【一手来源：https://docs.slint.dev/latest/docs/rust/slint/wgpu_30/ 】。也就是说，原型通过后，正式产品每次升 Slint 都可能要跟着升 wgpu 并改互操作代码【推测】。

### 1.2 API

- 选后端：`slint::BackendSelector::new().require_wgpu_30(WGPUConfiguration).select()`【读码：`slint@v1.18.1:internal/backends/selector/api.rs` `require_wgpu_30`】。
- `WGPUConfiguration` 有两种【一手来源：https://docs.slint.dev/latest/docs/rust/slint/wgpu_30/enum.WGPUConfiguration 】：
  - `Manual { instance, adapter, device, queue }`：自己建好 wgpu 交给 Slint。原型必须用这个，原因见 §2.1。
  - `Automatic(WGPUSettings)`：Slint 自己选。默认 `backends` 取 `Backends::from_env()`，没设环境变量就是 `Backends::all()`；默认限制是 `downlevel_webgl2_defaults()`【读码：`slint@v1.18.1:internal/core/graphics/wgpu_30.rs` `impl Default for WGPUSettings`；`wgpu@v30.0.1:wgpu-types/src/backend.rs` `impl Default for Backends`】。
- 拿 Slint 的 device/queue：`Window::set_rendering_notifier`，在 `RenderingSetup` 阶段收到 `GraphicsAPI::WGPU30 { device, queue, .. }`；每帧在 `BeforeRendering` 阶段可以做自己的 GPU 工作【一手来源：wgpu_30 模块文档；读码：`slint@v1.18.1:examples/wgpu_texture/`】。
- 导入纹理：`impl TryFrom<wgpu_30::Texture> for slint::Image`，错误类型 `TextureImportError { InvalidFormat, InvalidUsage }`【读码：`slint@v1.18.1:internal/core/graphics/wgpu_30.rs` `TryFrom::try_from`】。

### 1.3 格式和用途限制（仍在，略有放宽）

- 格式只收 `Rgba8Unorm` 和 `Rgba8UnormSrgb`（方案里写的"只收 Rgba8Unorm"要补上 Srgb 变体）；用途必须同时含 `TEXTURE_BINDING` 和 `RENDER_ATTACHMENT`【读码：同上；一手来源：https://docs.slint.dev/latest/docs/rust/slint/wgpu_30/enum.TextureImportError 】。
- 但 Skia 渲染器的 DX12 导入函数实际支持 `R8G8B8A8_UNORM`、`R8G8B8A8_UNORM_SRGB`、`B8G8R8A8_UNORM` 三种【读码：`slint@v1.18.1:internal/renderers/skia/wgpu_30_surface/dx12.rs` `import_dx12_texture`】。所以"放开 BGRA"在 Skia + DX12 上只差 core 里一处检查；FemtoVG 渲染器那边没细看，给上游提 PR 要连它一起处理【推测】。
- 导入的纹理一律按 `AlphaType::Unpremul` 处理，也没法声明"不透明"，会让 Skia 丢掉局部重绘（slint#13203，2026-10-22 仍 open）【一手来源：https://github.com/slint-ui/slint/issues/13203 】。视频画面每帧都变，局部重绘本来就省不了多少；hwcodec 的着色器输出 alpha=1，混合结果不受影响【推测】。

### 1.4 渲染器选择

- 支持 wgpu 纹理导入的渲染器：Skia、FemtoVG（wgpu 版）；vello 的支持（slint PR #13975）2026-10-12 才合并，不在 1.18.1 里【一手来源：https://github.com/slint-ui/slint/pull/13975 】。
- **原型用 Skia**，理由：
  - Skia 走 wgpu 时，Windows 上用 Skia 自己的 D3D12 后端，直接拿 wgpu 的原生 `ID3D12CommandQueue` 提交【读码：`dx12.rs` `make_dx12_context`】。这正好方便在同一条队列上插入跨 API 的 fence 等待（§2.4）。
  - FemtoVG 的 wgpu 版有个未修的问题：一旦设置了 rendering notifier，每帧都重建渲染管线（slint#12030，open）【一手来源：https://github.com/slint-ui/slint/issues/12030 】。视频上屏必须用 notifier，这个问题直接影响 60fps。
- Skia 的 wgpu 路径只接受 DX12 和 Vulkan 两种后端【读码：`slint@v1.18.1:internal/renderers/skia/wgpu_30_surface.rs` `Backend::new`】。

### 1.5 示例代码

官方 wgpu_30 模块文档里有完整示例（建 `Rgba8Unorm` 纹理，在 `RenderingSetup` 里 `Image::try_from` 后设到 `Image` 元素上）；仓库 `examples/wgpu_texture/` 演示了每帧在 `BeforeRendering` 里用 wgpu 渲染进纹理再导入的写法【一手来源：https://docs.slint.dev/latest/docs/rust/slint/wgpu_30/ ；读码：`slint@v1.18.1:examples/wgpu_texture/lib.rs` `main`】。原型的 UI 侧就照这个结构写，只是把"wgpu 渲染进纹理"换成"导入 D3D11 共享纹理"。

---

## 2. Windows 上把 D3D11 纹理交给 wgpu

### 2.1 wgpu 的后端

- wgpu 在 Windows 上的一级后端是 DX12 和 Vulkan，GL 是二级；没有 D3D11 后端【读码：`wgpu@v30.0.1:wgpu-types/src/backend.rs` `Backends::PRIMARY`】。
- 默认 `Backends::all()`，Slint 只额外避开 GL 和 Metal【读码：`slint@v1.18.1:internal/core/graphics/wgpu_30.rs` `default_backends_to_avoid`】。也就是说 `Automatic` 时 Vulkan 和 DX12 都可能被选中。有第三方项目说 wgpu 在 Windows 上默认落到 Vulkan【旁证：https://github.com/storytold/filmcraft/pull/152 】，具体选哪个看适配器枚举顺序，不确定。
- 所以原型要用 `Manual`：`Instance` 只开 `Backends::DX12`，枚举适配器后用 `adapter.as_hal::<Dx12>()` 拿 `IDXGIAdapter3`，读 `GetDesc1().AdapterLuid`，挑出和解码器同一块 GPU 的那个【读码：`wgpu@v30.0.1:wgpu-hal/src/dx12/mod.rs` `Adapter::as_raw`】。上游 Flutter 路径也是让解码器跟着渲染端的 LUID 走（下文 §4.3），方向反过来也行：先选 wgpu 适配器，再把它的 LUID 交给解码器。

### 2.2 共享路径

```
hwcodec 解码设备 (D3D11)                        Slint/wgpu 设备 (D3D12)
  NV12 解码面 ──像素着色器──> BGRA 环形纹理(4 张)
                                 │ 每帧一次 GPU 拷贝或直通绘制
                                 v
  桥接纹理（NT 句柄共享，RGBA 或 BGRA）──CreateSharedHandle──> OpenSharedHandle → ID3D12Resource
                                                               → wgpu_hal::dx12::Device::texture_from_raw
                                                               → wgpu::Device::create_texture_from_hal
                                                               → slint::Image::try_from
```

要点：

1. **D3D11 侧建可共享纹理**：`MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE`，`BindFlags` 含 `SHADER_RESOURCE | RENDER_TARGET`（Slint 要求导入的纹理带 `RENDER_ATTACHMENT` 用途，底层资源最好真有渲染目标标志【推测】），再用 `IDXGIResource1::CreateSharedHandle` 拿 NT 句柄。
2. **D3D12 侧打开**：`ID3D12Device::OpenSharedHandle(handle, ID3D12Resource)`。官方文档写的入参是 `CreateSharedHandle` 产出的 NT 句柄【一手来源：https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-opensharedhandle 】。
   - hwcodec 环形纹理和 Flutter 插件用的都是旧式 `D3D11_RESOURCE_MISC_SHARED` + `GetSharedHandle`（KMT 句柄）【读码，见 §3、§4】。有 Rust 项目把 KMT 句柄直接交给 D3D12 `OpenSharedHandle` 并且能用【旁证：https://docs.rs/mirror-graphics/latest/src/mirror_graphics/interop.rs.html 、https://docs.rs/vtsampler/latest/src/vtsampler/bridge/d3d11.rs.html 】，但官方文档没写支持，也有项目报 KMT 共享已被弃用、部分环境打不开【旁证：https://github.com/storycraft/asdf-overlay/issues/237 】。**原型一律用 NT 句柄的桥接纹理**，不直接打开 hwcodec 的环形纹理。
3. **包成 wgpu 纹理**（wgpu 30 的签名）【读码】：
   - `wgpu_hal::dx12::Device::texture_from_raw(resource, format, dimension, size, mip_level_count, sample_count) -> dx12::Texture`（`wgpu@v30.0.1:wgpu-hal/src/dx12/device.rs`）。
   - `unsafe wgpu::Device::create_texture_from_hal::<Dx12>(hal_texture, &TextureDescriptor, initial_state: wgt::TextureUses) -> Texture`（`wgpu@v30.0.1:wgpu/src/api/device.rs`）。注意 wgpu 30 比旧版多了 `initial_state` 参数，网上 wgpu 22~24 时代的示例少这个参数；已有项目对 D3D12 共享资源传 `TextureUses::UNINITIALIZED`【旁证：https://docs.rs/crate/grafting/latest/source/src/dx12_shared_texture.rs 】。
   - `TextureDescriptor.usage` 填 `TEXTURE_BINDING | RENDER_ATTACHMENT`，否则 Slint 报 `InvalidUsage`。
4. **只在分辨率变化时重建**：桥接纹理和它的 wgpu 包装按尺寸缓存，每帧只做 GPU 拷贝/绘制和同步。

wgpu 没有正式的"外部内存导入"API（wgpu#2320 "Texture memory import API" 2026-10-22 仍 open），上面这套全靠 hal 层的 unsafe 接口【一手来源：https://github.com/gfx-rs/wgpu/issues/2320 】。wgpu 的 Vulkan 后端倒是有现成的 `texture_from_d3d11_shared_handle`（PR #6161，2024-10 合并），但 Skia 在 Vulkan 上还得多一层，且原型不需要【一手来源：https://github.com/gfx-rs/wgpu/pull/6161 ；读码：`wgpu@v30.0.1:wgpu-hal/src/vulkan/device.rs` `texture_from_d3d11_shared_handle`】。

### 2.3 现成的开源参考

| 项目 | 做法 | 和原型的关系 |
|---|---|---|
| filmcraft PR #152（草稿） | Media Foundation 解码 → GPU 拷贝进 NT 句柄共享的 NV12/P010 纹理 → D3D12 `OpenSharedHandle` + `wgpu::hal::dx12`；同步用 `ID3D11Query` 事件等待；检查 DX12 + 同一 LUID；4K HEVC 每帧 CPU 从 17.5ms 降到 5.3ms | 最接近原型的 wgpu 30 时代实例，还记录了 FXC 编不过复杂 WGSL、要带 DXC 的坑【旁证：https://github.com/storytold/filmcraft/pull/152 】 |
| mirror-graphics、vtsampler | D3D11 纹理 `CopySubresourceRegion` 到共享纹理，D3D12 打开后 `create_texture_from_hal` | 代码结构可抄，但用的是 KMT 句柄、旧版 wgpu API【旁证，链接见上】 |
| cef-rs `osr_texture_import/d3d11.rs` | CEF 离屏渲染的 D3D11 共享句柄导入 wgpu DX12 | 同上【旁证：https://github.com/tauri-apps/cef-rs/blob/02cd5a01/cef/src/osr_texture_import/d3d11.rs 】 |
| taildesk PR #29 | 远程桌面客户端：NV12/I420 上传到 wgpu，着色器转 `Rgba8Unorm` 后直接 `slint::Image::try_from`；两个 Slint 窗口共用一个 device（`Manual`），各跑 1080p60 | 证明 Slint 多窗口 + wgpu 视频的结构可行，但只在软件 GPU 上跑过，没给真实帧率，也没做 D3D11 互操作【旁证：https://github.com/yurisanp/taildesk/pull/29 】 |
| Dawn（Chromium 的 WebGPU） | `SharedTextureMemoryDXGISharedHandle` / `SharedTextureMemoryD3D11Texture2D` + `SharedFenceDXGISharedHandle`，用共享 fence 同步 | 说明业界标准做法就是"NT 句柄 + 共享 fence"；wgpu 没有对应 API【一手来源：https://dawn.googlesource.com/dawn/+/main/src/dawn/native/d3d11/PhysicalDeviceD3D11.cpp 】 |

Moonlight-qt 在 Windows 上直接用 D3D11VA + D3D11 交换链显示，Sunshine 是被控端（抓屏/编码），OBS 的共享纹理在 D3D11 设备之间，都不涉及 D3D11→D3D12，参考价值有限【推测，没逐一读码】。

### 2.4 同步

- **D3D12 不直接用 keyed mutex。** 微软的 D3D11/D3D12 互操作文档推荐的模式是传"共享 fence + 值"：开始前等一个、结束后发一个，并说明这和 `IDXGIKeyedMutex` 的实现是同一套机制；D3D11 从 Windows 10 Creators Update（1703）起有 `ID3D11Fence` / `ID3D11Device5::CreateFence` / `ID3D11DeviceContext4::Signal/Wait`，专门用于和 D3D12 互操作【一手来源：https://learn.microsoft.com/en-us/windows/win32/direct3d12/direct3d-12-with-direct3d-11--direct-2d-and-gdi 、https://learn.microsoft.com/en-us/windows/win32/direct3d11/direct3d-11-4-features 、https://learn.microsoft.com/en-us/windows/win32/api/d3d11_4/nf-d3d11_4-id3d11device5-createfence 】。Porta 只支持 Win10 以上，满足。
- **hwcodec 已经在 CPU 上等转换完成**：`convert()` 里 `Nv12ToBgra` 之后 `EndQuery()` + `Query()`，`Query()` 轮询 `D3D11_QUERY_EVENT` 直到 GPU 做完（有超时）【读码：`hwcodec@ec38eba:cpp/ffmpeg_vram/ffmpeg_vram_decode.cpp` `FFmpegVRamDecoder::convert`；`cpp/common/platform/win/win.cpp` `NativeDevice::Query`】。所以回调拿到纹理时，BGRA 内容已经写完。
- **原型分两步**：
  1. 先求能跑：桥接拷贝/绘制之后，同样用事件查询在 CPU 上等完（filmcraft 也是这样），再通知 UI 线程。代价是视频线程每帧多阻塞一小段【推测：亚毫秒级，原型要量】。
  2. 再求正确又不阻塞：
     - D3D11→D3D12（读之前写完）：D3D11 侧 `ID3D11DeviceContext4::Signal(fence, n)`；UI 侧在 `BeforeRendering` 里取 wgpu 原生队列 `queue.as_hal::<Dx12>().as_raw()`，调 `ID3D12CommandQueue::Wait(fence, n)`。因为 Skia 用的就是这条队列，等待会排在它这一帧的绘制之前【读码：`dx12.rs` `make_dx12_context` 用 `queue.as_hal` 取原生队列；`wgpu@v30.0.1:wgpu-hal/src/dx12/mod.rs` `Queue::as_raw`】。
     - D3D12→D3D11（写之前读完）：桥接纹理做 2~3 张轮换；D3D12 渲染完 `Signal`，D3D11 覆写某张之前 `Wait` 对应值。`AfterRendering` 回调是否在 Skia 提交之后触发没读到，原型要确认【推测】。
- **资源状态**：Skia 导入 DX12 纹理时假定它处于 `D3D12_RESOURCE_STATE_PRESENT`（数值等于 COMMON）【读码：`dx12.rs` `import_dx12_texture`】；`OpenSharedHandle` 打开的共享资源在跨 API 交接时应处于 COMMON。路径 C（§3.2）里共享纹理只被 wgpu 读、交给 Slint 的是 wgpu 自己建的纹理，状态由 wgpu/Slint 管，Slint 官方示例就是这么用的；路径 A/B 把共享纹理直接交给 Slint，状态全靠 Skia 的假定。**原型全程开 D3D12 调试层**，看有没有状态告警【推测】。

---

## 3. BGRA → RGBA 放在哪

### 3.1 hwcodec 现在怎么出 BGRA【读码】

- 解码输出走 `FFmpegVRamDecoder::convert`：`USE_SHADER` 在文件开头写死定义，所以走像素着色器路径，不走 D3D11 视频处理器（`Process`）那条（`hwcodec@ec38eba:cpp/ffmpeg_vram/ffmpeg_vram_decode.cpp`）。
- 每个解码器建一个 `NativeDevice`，环形纹理 4 张（`native_->Init(luid_, device_, 4)`）；每帧 `next()` 换一张，`Nv12ToBgra` 往里画，回调交出 `GetCurrentTexture()`（同文件 `initialize` 附近、`decode`）。
- 环形纹理由 `NativeDevice::EnsureTexture` 创建：`Format = DXGI_FORMAT_B8G8R8A8_UNORM`，`MiscFlags = D3D11_RESOURCE_MISC_SHARED`，`BindFlags = SHADER_RESOURCE | RENDER_TARGET`；尺寸或格式不符时重建（`hwcodec@ec38eba:cpp/common/platform/win/win.cpp` `NativeDevice::EnsureTexture`）。
- 渲染目标视图格式写死 `DXGI_FORMAT_B8G8R8A8_UNORM`（`nv12_to_bgra_set_rtv`）。
- 像素着色器是预编译的 DXBC（`pixel_shader_601.h`，源码在 `dev/vs/ShaderCompileTool/nv_pixel_shader_601.hlsl`），输出一个 `float4 SV_TARGET`，即逻辑上的 RGBA；落到内存里是什么字节序由渲染目标格式决定。
- 解码设备：`D3D11CreateDevice` 只要特性级别 11_0，并开了多线程保护（`NativeDevice::InitFromLuid`、`SetMultithreadProtected`）。

### 3.2 四条路线

| 路线 | 做法 | 改动量 | 每帧额外 GPU 开销 | 评价 |
|---|---|---|---|---|
| A. 改 hwcodec 直接出 RGBA | `EnsureTexture` 两处格式（判断和创建）、`nv12_to_bgra_set_rtv` 一处格式改成 `R8G8B8A8_UNORM`；**着色器一行不用改** | C++ 改 3 行左右，但必须做成参数：同一个 `NativeDevice::EnsureTexture` 还被编码端自检（`ffmpeg_vram_encode.cpp`）用，Flutter 插件又写死按 BGRA8888 交给 Flutter（§4.2），全局改会弄坏这两处。加参数要穿过 `Init`、FFI、Rust 的 `DecodeContext`，估计几十行【推测】 | 0（之后仍要一次同格式 `CopyResource` 进 NT 句柄桥接纹理，除非连环形纹理也改成 NT 句柄） | 产品阶段最省，但 hwcodec 是 `rustdesk-org` 的独立仓库，要多维护一个 fork（方案 §2.1 没列它）|
| B. Porta 自己在 D3D11 上做一次直通绘制 | 采样环形纹理（BGRA 的 SRV），写进 RGBA 桥接纹理（RTV），像素着色器原样返回采样值 | Porta 侧 Rust 代码（windows crate 建着色器、视图、全屏三角形），约 100~200 行【推测】，hwcodec 不动 | 一次全屏绘制，**替代**原本就要做的那次 `CopyResource` | 不 fork hwcodec，开销和上游 Flutter 路径同级 |
| C. 在 wgpu 里换 | 桥接纹理用 BGRA（和环形纹理同格式，`CopyResource` 即可），导入 wgpu 成 `Bgra8Unorm`，再用一次 render pass 画进 wgpu 自建的 `Rgba8Unorm` 纹理交给 Slint | 全是 Rust + WGSL，最好写；wgpu 原生支持两种格式之间的采样和渲染 | 一次 `CopyResource` + 一次全屏绘制。4K 每帧约 33 MB 读写各一遍【推测：独显无压力，核显要量】 | **原型首选**：最快跑通，共享纹理只被 wgpu 读，资源状态最省心 |
| D. 给 Slint 提 PR 放开 BGRA | 去掉 core 里对 `Bgra8Unorm` 的拒绝，Skia DX12 已支持 | Slint 上游 PR；FemtoVG/vello 要一起处理【推测】 | 0 | 长期最干净，但取决于上游，原型不等它 |

不推荐：把 hwcodec 的 NV12 解码面直接交给 wgpu 自己做 YUV→RGB（filmcraft 的做法）。hwcodec 的 Rust 接口只交出 BGRA 纹理，NV12 解码面是 FFmpeg 帧池里的数组纹理，不可共享，要大改 hwcodec【读码：`hwcodec@ec38eba:src/vram/decode.rs` `DecodeFrame` 只有 `texture/width/height`】。也不推荐让 hwcodec 用 D3D11On12 设备解码（`DecodeContext.device` 可以传外部设备）：D3D11VA 在 11on12 上能否高效工作没有资料【推测】。

---

## 4. 客户端现在怎么把解码结果交给 Flutter

### 4.1 Rust 侧数据流【读码】

1. 视频线程解码：`scrap::codec::Decoder::handle_vram_video_frame` 调 `VRamDecoder::decode`，把 `DecodeFrame.texture`（即 `ID3D11Texture2D*`，裸指针）装进 `ImageTexture { texture: *mut c_void, w, h }`（`porta-client:libs/scrap/src/common/codec.rs`、`libs/scrap/src/common/mod.rs` `ImageTexture`、`libs/scrap/src/common/vram.rs` `VRamDecoder::decode`）。
2. `io_loop.rs` 里视频线程的回调：`pixelbuffer` 为假时调 `handler.on_texture(display, texture)`，只在 `vram` + `flutter` 两个特性都开时编译（`porta-client:src/client/io_loop.rs`，`start_video_thread` 附近的闭包）。
3. `FlutterHandler::on_texture` → 每个会话的 `VideoRenderer::on_texture`，找到该显示器注册的 `gpu_output_ptr`，调插件导出的 C 函数 `FlutterGpuTextureRendererPluginCApiSetTexture(output, texture)`，首次切换时给 Dart 发 `EventToUI::Texture`（`porta-client:src/flutter.rs` `VideoRenderer::on_texture`、`FlutterHandler::on_texture`）。
4. `gpu_output_ptr` 来自 Dart 调 `session_register_gpu_texture`（`src/flutter_ffi.rs`、`src/flutter.rs` `session_register_gpu_texture`）。
5. 解码器选 GPU：`VideoHandler::new` → `get_adapter_luid()` → 插件导出的 `FlutterGpuTextureRendererPluginCApiGetAdapterLuid`，取 Flutter 所在适配器的 LUID 交给 `Decoder::new(format, luid)`；不开 `flutter` 特性时 `get_adapter_luid` 直接返回 `None`（`src/client.rs` `VideoHandler::get_adapter_luid`；`src/flutter.rs` `get_adapter_luid`）。
6. `VRamDecoder::available` 只从 `HwCodecConfig::get().vram_decode` 里挑 FFmpeg 驱动、LUID 相同且非 0 的条目，这份配置要先由检测流程生成（`libs/scrap/src/common/vram.rs`）。
7. 构建：`vram` 特性只在 Windows x64 的 CI 矩阵里通过 `--vram` 打开（`porta-client:.github/workflows/flutter-build.yml`）。

### 4.2 插件 C++ 侧【读码：`flutter_gpu_texture_renderer@08a471b:windows/d3d11_output.cpp`】

- `D3D11Output::SetTexture` → `EnsureTexture`：从传进来的纹理取所属设备（就是解码器的 D3D11 设备），在该设备上按同样的描述建一张自己的纹理 `tex_buffers_`，`GetSharedHandle` 取**旧式** KMT 句柄，填进 `FlutterDesktopGpuSurfaceDescriptor`，格式写死 `kFlutterDesktopPixelFormatBGRA8888`；每帧 `CopyResource(tex_buffers_, tex_)` + `Flush()`，没有跨设备同步。
- Flutter 端用 `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` 注册纹理。
- 结论：**上游所谓"零拷贝"是"不回 CPU、每帧一次 GPU 拷贝"**，方案 §3.4 和 §3.4"换框架多花的成本"里的"零拷贝"建议照这个口径改写。

### 4.3 原型接哪个接口

- 不接 Flutter 插件，也不依赖 `porta-client` 的 `flutter`/`vram` 编译路径（那条路径被 `cfg(feature = "flutter")` 绑死）。
- 原型直接依赖 `hwcodec` crate（和客户端锁同一个提交 `febec27`，开 `vram` 特性），用三个接口：
  - `hwcodec::vram::decode::available()` → 按 LUID 和格式过滤出 `DecodeContext`（绕过 `HwCodecConfig` 的检测缓存）；
  - `hwcodec::vram::decode::Decoder::new(ctx)`；
  - `Decoder::decode(&[u8]) -> &mut Vec<DecodeFrame>`，拿 `DecodeFrame.texture` 当 `ID3D11Texture2D*` 用，用 `ID3D11DeviceChild::GetDevice` 取解码设备。
  【读码：`hwcodec@ec38eba:src/vram/decode.rs`、`src/vram/mod.rs` `DecodeContext`】
- 纹理指针的有效期：环形纹理 4 张轮换，指针在 4 帧后会被覆写，所以必须在回调所在的视频线程里**立即**做桥接拷贝/绘制，和 Flutter 插件一样【读码 + 推测】。
- 正式迁移时，对应的挂钩点就是 `io_loop.rs` 里那个回调和 `UiHandler::on_texture` 这个 trait 方法（`src/ui_session_interface.rs`），新界面实现自己的 `on_texture` 即可，引擎不用动【读码】。

---

## 5. 另两条标准在 Slint 上的已知问题

### 5.1 标准 1：1080p60 / 4K60

- 没找到 Slint 官方关于"外部纹理视频 60fps"的基准或 issue。相关的：
  - FemtoVG wgpu 版用 notifier 时每帧重建管线（slint#12030，open），所以用 Skia【一手来源，见 §1.4】。
  - Skia 导入纹理丢失局部重绘（slint#13203，open），视频场景影响小【一手来源，见 §1.3】。
  - Skia 的 wgpu 交换链偏好 FIFO（垂直同步）呈现模式【读码：`wgpu_30_surface.rs` `init_with_parts` 附近注释】。远程桌面对延迟敏感，原型要记录"解码完成到上屏"的延迟，必要时比较 Mailbox【推测】。
- 每帧要把新图交给 Slint：`Image::try_from` 只是包一层，可以同一张 wgpu 纹理反复用，只调 `window.request_redraw()`；Skia 每帧会 `Image::from_texture` 一次，开销没数据【读码 + 推测】。
- 真实解码源：`porta-client:libs/scrap/examples/benchmark.rs` 已有"抓屏 → `HwRamEncoder` → `HwRamDecoder`"的流程，可以改成先编好一段码流存内存，再按 60fps 节奏循环喂给 vram 解码器【读码】。4K 源要一块 4K 屏或远端 4K 被控端，见待拍板问题。

### 5.2 标准 3：多窗口、中文输入法、高 DPI（Windows）

**多窗口**
- Slint 一个进程里原生支持多个窗口；`Manual` 配置下所有窗口共用一个 wgpu device/queue，taildesk 的两窗口实验就是这样【旁证：taildesk PR #29】。
- Windows 上 winit 的 `request_redraw` 不节流；有用户报两个窗口都持续请求重绘时，失焦窗口内容不更新、性能明显变差。维护者建议改用 Slint 自己的 `Window::request_redraw()`，报告者说有改善但没完全解决【一手来源：https://github.com/slint-ui/slint/discussions/8823 】。
- 多窗口内存泄漏 slint#11266 已在 2026-05 关闭【一手来源：https://github.com/slint-ui/slint/issues/11266 】。

**中文输入法**
- 输入时组字串在输入框下方多显示一份（slint#5982）：winit 0.30.13 修复，Slint 侧 `cargo update` 即可【一手来源：https://github.com/slint-ui/slint/issues/5982 】。
- 搜狗输入法候选框不跟随光标、固定在屏幕底部：Slint 把它转给 winit（winit#2780），winit 那边 2026-10-22 仍 open【一手来源：https://github.com/slint-ui/slint/issues/2658 、https://github.com/rust-windowing/winit/issues/2780 】。
- 切到微软拼音时界面卡死：多人报告，维护者复现不了，以重复为由关闭（slint#8716）【一手来源：https://github.com/slint-ui/slint/issues/8716 】。
- 窗口失焦时最后一个正在组字的字被丢（韩文输入法报告，slint#10861，open）【一手来源：https://github.com/slint-ui/slint/issues/10861 】。中文输入法是否同样，原型要测【推测】。
- 有用户反馈 Windows 上 FemtoVG 渲染器配微软拼音能用【一手来源：slint#4698 评论，https://github.com/slint-ui/slint/issues/4698 】。
- 远程会话窗口里键盘要转发给被控端，RustDesk 在 Windows 上用的是引擎层的键盘钩子，和界面框架关系不大；但"会话窗口抢焦点时关掉 IME"这类行为要在新框架里重新做【推测】。

**高 DPI**
- 混合 DPI 双屏之间拖动窗口，窗口越拖越大（slint#11073，open）。根因在 winit 0.30 的 `WM_DPICHANGED` 处理；winit 主分支已修（winit#4341），没回到 0.30 分支（winit#4600 open），Slint 要等升级 winit 0.31（slint#11243 open）。社区有人在自己的应用里给 winit 0.30.13 打补丁绕过【一手来源：https://github.com/slint-ui/slint/issues/11073 、https://github.com/rust-windowing/winit/issues/4600 、https://github.com/slint-ui/slint/issues/11243 】。
- `set_position` 之后 scale factor 错误（slint#5701，open）【一手来源：https://github.com/slint-ui/slint/issues/5701 】。
- "系统缩放不生效"（slint#11641）2026-09 已关闭【一手来源：https://github.com/slint-ui/slint/issues/11641 】。

---

## 6. 原型最小实施步骤（3~5 天）

范围：一个独立的 Rust 二进制（放在 Porta 总仓库的实验目录或单独仓库，不进 `porta-client`），只做 Windows x64、H.264/H.265 vram 解码、一个 Slint 窗口起步再扩到两个。不做网络、不做会话。

| 步 | 内容 | 判定方法 | 预计 |
|---|---|---|---|
| 0 | 工具链：Rust（Slint 1.18.1 要求 rustc ≥ 1.92【一手来源：crates.io 元数据 `rust_version`】）、FFmpeg 依赖按 hwcodec 的构建要求准备；Slint 1.18.1 开 `unstable-wgpu-30`、`renderer-skia`，wgpu 钉 30.0.1 | `cargo build` 过 | 0.5 天 |
| 1 | `Manual` 配置：只开 DX12，按 LUID 选适配器，`require_wgpu_30`；照官方示例显示一张 CPU 上传的绿色 `Rgba8Unorm` 纹理 | 窗口正常显示；日志打印 `adapter_info().backend == Dx12` 和 LUID | 0.5 天 |
| 2 | 解码源：改 `scrap` 的 benchmark 流程，抓屏编码出 1080p 的 H.264 码流存内存（4K 源另找）；用 hwcodec `vram::decode` 以步骤 1 的 LUID 建解码器，循环解码 | 每帧拿到非空 `ID3D11Texture2D*`，描述为 BGRA、尺寸正确；解码速率 ≥ 60fps | 0.5~1 天 |
| 3 | 互操作（路线 C）：解码设备上建 NT 句柄共享的 BGRA 桥接纹理 → D3D12 `OpenSharedHandle` → `texture_from_raw` + `create_texture_from_hal`（`Bgra8Unorm`，`TEXTURE_BINDING`）；wgpu 建 `Rgba8Unorm` 目标纹理，`BeforeRendering` 里一次直通 render pass；目标纹理 `Image::try_from` 一次，之后每帧只 `request_redraw` | 画面颜色正确（拿已知色块帧对比，红蓝没反）；D3D12 调试层无报错；PIX 或 GPUView 抓一帧确认没有 CPU 回读/上传 | 1 天 |
| 4 | 同步：先用事件查询 CPU 等待；再换共享 fence（D3D11 `Signal` / D3D12 队列 `Wait`）+ 桥接纹理 3 张轮换 | 快速运动画面连续播 10 分钟无撕裂、无花屏、无旧帧回跳；记录视频线程每帧阻塞时间 | 0.5~1 天 |
| 5 | 性能：1080p60、4K60 各跑 5 分钟，打开 `SLINT_DEBUG_PERFORMANCE` 看实际帧率；记录 CPU 占用、GPU 占用、解码完成到呈现的延迟；同场景和现有 RustDesk Flutter 客户端对比 | 两个分辨率都稳定 60fps（允许偶发掉帧，定个阈值如 99% 帧间隔 < 20ms）；CPU 占用不高于 Flutter 客户端 | 0.5 天 |
| 6 | 标准 3：开第二个窗口各放一路视频；混合 DPI 双屏拖动；微软拼音、搜狗在 `LineEdit` 里输入中文，切换输入法，失焦时组字 | 两窗口都 60fps，失焦窗口也更新；拖动后窗口逻辑尺寸不变；候选框位置正确、不卡死、不丢字。逐项记录通过/不通过及 issue 号 | 0.5~1 天 |
| （可选）7 | 路线 A/B 对比：fork hwcodec 加 RGBA 输出参数，或 Porta 侧 D3D11 直通绘制，去掉 wgpu 那次额外绘制 | 帧时间、GPU 占用是否有可测差异 | 0.5 天 |

失败判据（任一出现就按方案"原型不通过，留 Flutter"处理）：步骤 3 在主流三家 GPU 中任一家上打不通且无绕法；步骤 5 4K60 达不到且瓶颈在 Slint/Skia 而不在解码；步骤 6 有阻断使用的问题且上游没有修复时间表。

---

## 7. 对第二期方案的影响

- 方案 §3.4 第 2 条的"零拷贝"建议改成"不回 CPU、每帧至多一两次 GPU 拷贝或绘制"，和上游 Flutter 路径同口径（§4.2）。
- 方案 §3.4"Slint 的风险"里"只收 `Rgba8Unorm`"补成"只收 `Rgba8Unorm`/`Rgba8UnormSrgb`，Skia DX12 内部其实支持 BGRA，差 core 一处检查"（§1.3）。
- 如果最终走路线 A，`hwcodec` 要加入 fork 清单（§2.1 平台原生部分没有它）；走 B/C 则不用。
- 正式采用 Slint 后，"每次升 Slint 就跟着升 wgpu 并改 hal 层 unsafe 代码"是长期维护成本（§1.1）。
- 第 3 条里 DPI 和搜狗候选框的问题根子在 winit 0.30，可能要等 Slint 升 winit 0.31，或者 Porta 自己给 winit 打补丁（§5.2）。
