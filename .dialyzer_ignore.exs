[
  # Gettext's generated backend passes Expo's plural-forms struct (opaque
  # to Expo) to Gettext.Plural.plural/2. It appears once per locale with
  # plural messages, in code we don't write (see FireflyWeb.Gettext).
  {"lib/firefly_web/gettext.ex", :call_without_opaque},
  # OpenTelemetry's log handler reads its options (the exporter) from the
  # top level of its handler config, which logger's handler config type
  # doesn't list (see FireflyWeb.OpenTelemetry).
  {"lib/firefly_web/open_telemetry.ex", :call},
  {"lib/firefly_web/open_telemetry.ex", :no_return}
]
