<div class="title-block" style="text-align: center;" align="center">

# OpenTelemetry Zig

<p><img title="Zero OTel logo" src="images/zero-otel.png" width="320"></p>

**[Zig docs] &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Modules](#modules) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Contributing](#contributing) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Community](#join-the-community)**

[Zig docs]: https://open-telemetry.github.io/opentelemetry-zig/

</div>

> [!CAUTION]
> This project is in **alpha** stage. While it is ready for usage and testing, it has not been battle-tested in production environments. Use with caution and expect breaking changes between releases.

This is an implementation of the [OpenTelemetry](https://opentelemetry.io) specification for the [Zig](https://ziglang.org) programming language.

The version of the OpenTelemetry specification targeted here is **1.48.0**.

## Goals

1. Provide a Zig library implementing the _stable_ features of an OpenTelemetry SDK
1. Provide a reference implementation of the OpenTelemetry API
1. Provide examples on how to use the library in real-world use cases

> [!IMPORTANT]
> We are currently seeking additional contributors! See [help wanted](#help-wanted) for details.

## Modules

This repository is organized as multiple self-contained modules, each in its own
top-level directory with its own README:

- **[opentelemetry-sdk](./opentelemetry-sdk/README.md)** - the OpenTelemetry API and SDK: traces, metrics, logs, baggage, OTLP exporters, and C bindings. Start here for installation, features, and usage.
- **[opentelemetry-proto](./opentelemetry-proto/README.md)** - Zig protobuf bindings for the OpenTelemetry (OTLP) data model, generated from the official `.proto` definitions.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on how to contribute to this project, including:

- Running tests locally
- Running benchmarks
- Test and benchmark options

Refer to [MAINTAINERS.md](./MAINTAINERS.md) if you want to get in touch with the people involved in the Zig SIG.

## Origins

This project originated from a proposal in the OpenTelemetry community to create a native Zig implementation of the OpenTelemetry SDK.

You can read more about the original proposal and discussion at:

https://github.com/open-telemetry/community/issues/2514

## Join the community

You can find the Zig OTel SDK developers in the CNCF Slack [#otel-zig](https://cloud-native.slack.com/archives/C0B4RTXTBEV) channel.

## Help Wanted

We are currently resource constrained and are actively seeking new contributors interested in working towards [approver](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#approver) / [maintainer](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#maintainer) roles. In addition to the documentation for approver / maintainer roles and the [contributing](./CONTRIBUTING.md) guide, here are some additional notes on engaging:

- [Pull request](https://github.com/open-telemetry/opentelemetry-zig/pulls) reviews are equally or more helpful than code contributions. Comments and approvals are valuable with or without a formal project role. They're also a great forcing function to explore a fairly complex codebase.
- Attending the [Zig SDK](https://github.com/open-telemetry/community#calendar) Special Interest Group (SIG) is a great way to get to know community members and learn about project priorities.
- Issues labeled [help wanted](https://github.com/open-telemetry/opentelemetry-zig/issues?q=is%3Aopen+is%3Aissue+label%3A%22help+wanted%22) are project priorities. Code contributions (or pull request reviews when a PR is linked) for these issues are particularly important.
- Triaging / responding to new issues and discussions is a great way to engage with the project.
