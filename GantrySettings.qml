import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: GantryService.pluginId

    StyledText {
        width: parent.width
        text: "Gantry Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Configure how containers are monitored and managed from your bar."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Column {
        id: runtimesSetting

        readonly property string settingKey: "runtimes"
        property var items: GantryService.defaults.runtimes

        width: parent.width
        spacing: Theme.spacingS

        // PluginSettings calls loadValue() on every child that defines it, both
        // on first show and whenever the plugin's data changes elsewhere.
        function loadValue() {
            items = GantryService.normalizeRuntimes(root.loadValue(settingKey, GantryService.defaults.runtimes));
        }

        function updateItem(index, changes) {
            const next = items.map((rt, i) => i === index ? Object.assign({}, rt, changes) : Object.assign({}, rt));
            items = next;
            root.saveValue(settingKey, next);
        }

        Component.onCompleted: Qt.callLater(loadValue)

        StyledText {
            text: "Container Runtimes"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Enable the runtimes you want Gantry to monitor. Containers from every enabled runtime appear in one list."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: runtimesSetting.items

            Column {
                required property int index
                required property var modelData

                width: runtimesSetting.width
                spacing: Theme.spacingXS
                topPadding: Theme.spacingXS

                DankToggle {
                    width: parent.width
                    text: modelData.label
                    description: modelData.enabled ? "Monitored" : "Not monitored"
                    checked: modelData.enabled
                    onToggled: isChecked => runtimesSetting.updateItem(index, {
                            enabled: isChecked
                        })
                }

                DankTextField {
                    width: parent.width
                    enabled: modelData.enabled
                    opacity: modelData.enabled ? 1 : 0.5
                    text: modelData.binary
                    placeholderText: modelData.id
                    onEditingFinished: {
                        if (text !== modelData.binary)
                            runtimesSetting.updateItem(index, {
                                binary: text
                            });
                    }
                }
            }
        }
    }

    SliderSetting {
        settingKey: "debounceDelay"
        label: "Debounce Delay"
        description: "Delay before refreshing container list after container events (prevents excessive updates during rapid changes)."
        defaultValue: GantryService.defaults.debounceDelay
        minimum: 100
        maximum: 2000
        unit: "ms"
        leftIcon: "schedule"
    }

    SliderSetting {
        settingKey: "pollingInterval"
        label: "Background Polling Interval"
        description: "Fallback polling interval to refresh container state. Useful when event-based updates don't work reliably in the background. Set to 0 to disable polling."
        defaultValue: GantryService.defaults.pollingInterval
        minimum: 0
        maximum: 120000
        unit: "ms"
        leftIcon: "sync"
    }

    StringSetting {
        settingKey: "terminalApp"
        label: "Terminal Application"
        description: "Command used to launch terminal windows for exec and logs."
        defaultValue: GantryService.defaults.terminalApp
        placeholder: GantryService.defaults.terminalApp
    }

    StringSetting {
        settingKey: "shellPath"
        label: "Shell Path"
        description: "Shell to use when executing commands in containers (note: many containers will only have /bin/sh installed.)"
        defaultValue: GantryService.defaults.shellPath
        placeholder: GantryService.defaults.shellPath
    }

    ToggleSetting {
        settingKey: "showPorts"
        label: "Show Port Mappings"
        description: "Display container port mappings when expanding containers in the widget."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoScrollOnExpand"
        label: "Auto-scroll on Expand"
        description: "Automatically scroll to show expanded content when expanding containers or projects (smoothly follows the expansion animation)."
        defaultValue: true
    }
}
