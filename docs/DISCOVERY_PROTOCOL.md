# CIA Bridge FBI discovery protocol

[简体中文](#简体中文)

CIA Bridge uses a stateless, versioned UDP exchange to find compatible FBI
receivers on the local IPv4 subnet. This discovery exchange is separate from,
and does not modify, FBI's existing TCP URL-transfer protocol.

| Field | Version 1 value |
| --- | --- |
| Transport | UDP over IPv4 |
| Receiver port | `5001` |
| Request bytes | `CIA_BRIDGE_DISCOVER_V1` |
| Response bytes | `CIA_BRIDGE_FBI_V1;tcp=5000` |

The sender broadcasts the request as ASCII bytes without a NUL, newline, or
length prefix. A compatible FBI instance responds by unicast to the datagram's
source address and source port. The sender uses the response source address as
the console IPv4 address and the decimal `tcp` field as the normal FBI target
port.

FBI binds the discovery endpoint only while **Remote Install → Receive URLs
over the network** is active. It ignores malformed packets. Failure to bind UDP
5001 does not disable the regular TCP receiver.

CIA Bridge accepts only exact `V1` messages from its selected `/24` subnet. If
there is no valid response, it falls back to Nintendo-MAC discovery, safe
Android reachability candidates, and manual IP entry. This keeps stock and
older FBI builds compatible without probing TCP/5000.

## 简体中文

CIA Bridge 使用无状态、带版本号的 UDP 报文，在本地 IPv4 网段中发现兼容
的 FBI 接收端。该发现过程与 FBI 原有的 TCP URL 传输协议彼此独立，不改变
原协议。

- FBI 仅在 `Remote Install → Receive URLs over the network` 界面打开时监听
  UDP `5001`。
- CIA Bridge 发送 ASCII 请求 `CIA_BRIDGE_DISCOVER_V1`。
- FBI 向请求来源单播回复 `CIA_BRIDGE_FBI_V1;tcp=5000`。
- CIA Bridge 使用回复报文的来源 IP，并把 `tcp` 字段作为正常发送端口。
- 请求或回复都不包含结尾 NUL、换行或长度字段。

若没有合法回复，CIA Bridge 会依次回退到 Nintendo MAC 识别、Android 安全
可达候选和手动 IP，因此原版及旧版 FBI 仍可使用，也不会为了探测而连接
TCP/5000。
