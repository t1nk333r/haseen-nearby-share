pragma Singleton

import QtQuick

// This plugin's two halves live in the same directory but are loaded by
// different hosts: Service.qml is the shell's `service` singleton, Panel.qml is
// a bar widget built once per monitor as a *view* onto it.
//
// The view normally gets there through `bar.shell.serviceFor(id)`. That works
// only while Omarchy's own bar hosts the widget: Bar.qml's `pluginBarApiFor`
// can hand a widget a service-capable façade only if the bar it is placing into
// was given `pluginShellForId`, which a replacement bar never receives. This
// machine runs a replacement bar (`t1nk33r.bar`), so the bar is handed
// `pluginShellForBarEntry` instead - a façade of `_summon/_hide/_toggle/
// _isOpen/_updateSettings` with no `_serviceLookup` at all. `serviceFor()` is
// then null by construction, and not because the service is late: the widget
// paints the "turned off" colour, the popup says the engine is not loaded, and
// nothing in it can start anything, while the service runs and answers IPC the
// whole time.
//
// So the service publishes itself here instead. Both halves import this
// directory, and a QML singleton is one instance per engine - the "shared
// services live once, not once per process" the shell's own README asks for -
// so the view is never left without its engine, whatever bar is hosting it.
// The shell's lookup still wins when it answers; this is the fallback, not a
// second engine. See tests/qml.test.sh, which fails if the view goes back to
// the shell lookup alone.
QtObject {
  id: bridge

  property var service: null
}
