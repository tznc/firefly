[
  # Gettext's generated backend passes Expo's plural-forms struct (opaque
  # to Expo) to Gettext.Plural.plural/2. It appears once per locale with
  # plural messages, in code we don't write (see FireflyWeb.Gettext).
  {"lib/firefly_web/gettext.ex", :call_without_opaque}
]
