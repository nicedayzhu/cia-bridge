# FBI Remote Install 协议

CIA Bridge 实现 FBI 的两个远程安装入口。

## 二维码入口

二维码内容是一个 HTTP URL，多个文件时则以换行分隔 URL。CIA Bridge 启动临时 HTTP 文件服务，二维码指向同一局域网中的手机或电脑；文件较多导致二维码过密时，推荐改用 TCP 推送。

## TCP URL 推送入口

FBI 的 `Receive URLs over the network` 默认在 3DS 的 `TCP/5000` 监听。客户端发送：

```text
uint32  payload_size   网络字节序（大端）
byte[]  payload        ASCII URL；多个 URL 以 LF (0x0A) 分隔
```

FBI 读取 URL 后进入安装确认/处理流程。处理结束时，它发送一个确认字节并关闭连接。CIA Bridge 等待该字节，用它更新“FBI 已确认”的状态。

文件名先按 UTF-8 编码，再对 URL path 做百分号编码，因此交给 FBI 的完整 URL 仍为 ASCII。

参考：

- <https://github.com/Steveice10/FBI/blob/master/source/fbi/remoteinstall.c>
- <https://github.com/Steveice10/FBI/blob/master/servefiles/servefiles.py>
