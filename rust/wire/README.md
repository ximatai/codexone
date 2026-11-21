# Rust wire

独立 Cargo crate，提供有序 JSON 与上游 SSE 分帧。SSE 每次最多交付一帧，调用方可以先处理该帧的 JSON 和原始字节，再从同一个 chunk 继续读取。

## Swift 兼容边界

SSE 以发布平台 Linux 的 Swift 行为为准。帧内 `CR CR LF` 经一轮 CRLF 归一化后仍形成一个 CRLF 字符，Linux Swift 保留在同一行，macOS Swift 在 LF 处分行。帧分隔符仍为两个 LF 或两个 CRLF。

Swift Foundation 将非标准标记 `FE FF 00 00` 解码为 UTF-32LE。Swift 的顺序恢复在此路径回退到各层对象键排序，Rust 复现排序和普通重复键取首值。Images 指定的根键仍按解转义后的名称检查重复。Swift 在这条编码路径会接受重复的控制字段，Rust 返回 `invalid_json`。

## 本地验证

从仓库根目录运行。差分脚本使用固定种子 8093，编译当前 checkout 的 Swift wire 源码，比较 JSON/SSE 输出字节、错误码、SSE 状态和出错时已消费的字节数。Linux 可使用本机 Swift 6.4.1，也可用仓库验证所用的镜像。在 macOS 使用本机 Swift 时，脚本单独报告上述 CRCRLF 差异。

```sh
cargo test --locked --manifest-path rust/wire/Cargo.toml
python3 rust/wire/tools/differential.py
python3 rust/wire/tools/differential.py --swift-image swift:6.4.1-noble
```

## SSE 发布模式对照

```sh
cargo run --locked --release --manifest-path rust/wire/Cargo.toml --example wire-sse-benchmark
```

比较前后版本时，使用同一份 [基准源文件](tools/sse_benchmark.rs)。旧版本可将文件复制到其 crate 的 `examples/wire-sse-benchmark.rs`，然后运行同一命令。

以 64 KiB 分块送入合成流，包含分帧、JSON 解码及一次帧读取。每轮重复 20 次，报告 7 轮每条流耗时的中位数。Rust 1.100.0，Linux arm64 musl 容器，同机顺序运行。

| 流 | 输入字节 | 帧数 | 逐字节扫描 | 分块扫描 |
| --- | ---: | ---: | ---: | ---: |
| 大 JSON 事件 | 4,194,362 | 1 | 30.324 ms | 6.529 ms |
| 密集小帧 | 1,638,400 | 65,536 | 27.536 ms | 18.501 ms |
