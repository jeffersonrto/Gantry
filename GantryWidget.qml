import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ------------------------------------------------------------------
    // Navigation state
    //
    // Three levels, one at a time: the sheet replaces the list rather than
    // stacking on top of it. Container sheets are reachable from both the
    // container list and a project sheet, so `level` alone is not enough to
    // know where Back should return to -- openProjectKey carries that.
    // ------------------------------------------------------------------
    property bool groupByCompose: pluginData.groupByCompose || false
    property string level: "root"
    property string openProjectKey: ""
    property string openContainerKey: ""
    property string sheetSection: "actions"
    property int selectedIndex: 0
    property bool keyboardActive: false

    // Actions in flight, keyed by the target's key. Per target rather than
    // global, so opening another sheet mid-action neither shows the spinner on
    // the wrong row nor blocks the new target.
    property var pendingActions: ({})

    property string toastKind: ""
    property string toastTitle: ""
    property string toastDetail: ""

    property int nowTick: 0

    PluginGlobalVar {
        id: globalRuntimeAvailable
        varName: "runtimeAvailable"
        defaultValue: ({})
    }

    PluginGlobalVar {
        id: globalContainers
        varName: "containers"
        defaultValue: []
    }

    PluginGlobalVar {
        id: globalRunningContainers
        varName: "runningContainers"
        defaultValue: 0
    }

    PluginGlobalVar {
        id: globalComposeProjects
        varName: "composeProjects"
        defaultValue: []
    }

    readonly property var availableRuntimeIds: {
        const map = globalRuntimeAvailable.value || {};
        return Object.keys(map).filter(id => map[id]);
    }
    readonly property int checkedRuntimeCount: Object.keys(globalRuntimeAvailable.value || {}).length
    readonly property bool anyRuntimeAvailable: availableRuntimeIds.length > 0
    readonly property bool partiallyDown: anyRuntimeAvailable && availableRuntimeIds.length < checkedRuntimeCount
    readonly property var downRuntimeIds: {
        const map = globalRuntimeAvailable.value || {};
        return Object.keys(map).filter(id => !map[id]);
    }

    // A badge only earns its place when it tells items apart.
    readonly property bool showBadges: checkedRuntimeCount > 1 && availableRuntimeIds.length > 1

    readonly property var rootList: groupByCompose ? globalComposeProjects.value : globalContainers.value

    readonly property var openProject: {
        if (!openProjectKey)
            return null;
        return globalComposeProjects.value.find(p => p.key === openProjectKey) || null;
    }

    readonly property var openContainer: {
        if (!openContainerKey)
            return null;
        return globalContainers.value.find(c => c.key === openContainerKey) || null;
    }

    readonly property var sheetActions: {
        if (level === "container")
            return openContainer ? containerActions(openContainer) : [];
        if (level === "project")
            return openProject ? projectActions(openProject) : [];
        return [];
    }

    readonly property var sheetServices: (level === "project" && openProject) ? openProject.containers : []

    readonly property string sheetPendingAction: {
        if (level === "container")
            return pendingFor(openContainerKey);
        if (level === "project")
            return pendingFor(openProjectKey);
        return "";
    }

    // A compose action touches every service of the project, and a service
    // action touches the project, so each blocks the other while in flight.
    readonly property bool sheetRelatedBusy: {
        if (level === "container" && openContainer && openContainer.composeProject)
            return pendingFor(`${openContainer.runtime}:${openContainer.composeProject}`) !== "";
        if (level === "project" && openProject)
            return openProject.containers.some(c => pendingFor(c.key) !== "");
        return false;
    }

    readonly property bool sheetBlocked: sheetPendingAction !== "" || sheetRelatedBusy

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function stateColor(container) {
        if (!container)
            return Theme.surfaceVariantText;
        if (container.health === "unhealthy")
            return Theme.error;
        if (container.isPaused)
            return Theme.warning;
        if (container.isRunning)
            return Theme.primary;
        return Theme.surfaceVariantText;
    }

    function runtimeTint(runtimeId) {
        return runtimeId === "podman" ? Theme.warning : Theme.primary;
    }

    // Shown instead of the image for anything that is not running.
    function secondaryText(container) {
        if (!container)
            return "";
        if (container.isPaused)
            return "paused";
        if (container.isRunning)
            return container.image;
        if (container.state === "created")
            return "created";
        return `${container.state || "exited"} (${container.exitCode})`;
    }

    function formatUptime(startedAt) {
        const seconds = Math.floor((Date.now() - startedAt) / 1000);
        if (!startedAt || seconds < 0 || !isFinite(seconds))
            return "";

        const units = [
            {
                label: "d",
                size: 86400
            },
            {
                label: "h",
                size: 3600
            },
            {
                label: "m",
                size: 60
            },
            {
                label: "s",
                size: 1
            }
        ];

        const parts = [];
        let rest = seconds;
        for (const unit of units) {
            const value = Math.floor(rest / unit.size);
            if (value > 0 || parts.length > 0) {
                if (value > 0)
                    parts.push(`${value}${unit.label}`);
                if (parts.length === 2)
                    break;
            }
            rest = rest % unit.size;
        }
        return parts.length > 0 ? parts.join(" ") : "0s";
    }

    // Replicas of one service would all read the same, so they get the replica
    // number the runtime gave them.
    function serviceLabel(container, siblings) {
        if (!container.composeService)
            return container.name;
        const replicas = (siblings || []).filter(c => c.composeService === container.composeService).length;
        if (replicas < 2)
            return container.composeService;
        const number = container.composeNumber || (container.name.match(/[-_](\d+)$/) || [])[1];
        return number ? `${container.composeService}-${number}` : container.name;
    }

    function containerActions(container) {
        const list = [];
        if (container.isRunning)
            list.push({
                id: "restart",
                label: "Restart",
                icon: "refresh"
            });
        else if (!container.isPaused)
            list.push({
                id: "start",
                label: "Start",
                icon: "play_arrow"
            });

        if (container.isPaused)
            list.push({
                id: "unpause",
                label: "Unpause",
                icon: "play_arrow"
            });
        else if (container.isRunning)
            list.push({
                id: "pause",
                label: "Pause",
                icon: "pause"
            });

        if (container.isRunning || container.isPaused)
            list.push({
                id: "stop",
                label: "Stop",
                icon: "stop"
            });

        if (container.isRunning)
            list.push({
                id: "shell",
                label: "Shell",
                icon: "terminal"
            });

        list.push({
            id: "logs",
            label: "Logs",
            icon: "description"
        });
        return list;
    }

    function projectActions(project) {
        const list = [];
        if (project.runningCount < project.totalCount)
            list.push({
                id: "start",
                label: "Start all",
                icon: "play_arrow"
            });
        list.push({
            id: "restart",
            label: "Restart all",
            icon: "refresh"
        });
        if (project.runningCount > 0)
            list.push({
                id: "stop",
                label: "Stop all",
                icon: "stop"
            });
        list.push({
            id: "logs",
            label: "View logs",
            icon: "description"
        });
        return list;
    }

    // Two projects can share a name across runtimes. Then the badge is the only
    // thing telling the rows apart, so it shows even with a single runtime up.
    function projectShowsBadge(project) {
        if (root.showBadges)
            return true;
        return globalComposeProjects.value.filter(p => p.name === project.name).length > 1;
    }

    function pastTense(action) {
        return ({
                start: "started",
                stop: "stopped",
                restart: "restarted",
                pause: "paused",
                unpause: "unpaused"
            })[action] || action;
    }

    // ------------------------------------------------------------------
    // Toast
    // ------------------------------------------------------------------
    function showToast(kind, title, detail) {
        root.toastKind = kind;
        root.toastTitle = title;
        root.toastDetail = detail || "";
        toastTimer.interval = kind === "error" ? 6000 : 2000;
        toastTimer.restart();
    }

    function clearToast() {
        root.toastKind = "";
        root.toastTitle = "";
        root.toastDetail = "";
        toastTimer.stop();
    }

    Timer {
        id: toastTimer
        repeat: false
        onTriggered: root.clearToast()
    }

    Timer {
        id: uptimeTimer
        interval: 30000
        repeat: true
        running: root.level === "container"
        onTriggered: root.nowTick++
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------
    function pendingFor(key) {
        return (key && root.pendingActions[key]) || "";
    }

    function setPending(key, actionId) {
        const next = Object.assign({}, root.pendingActions);
        if (actionId)
            next[key] = actionId;
        else
            delete next[key];
        root.pendingActions = next;
    }

    function runContainerAction(container, actionId) {
        if (!container)
            return;

        if (actionId === "shell") {
            if (!GantryService.openExec(container.runtime, container.id || container.name))
                root.showToast("error", `Could not open a shell in ${container.name}`, "");
            return;
        }
        if (actionId === "logs") {
            if (!GantryService.openLogs(container.runtime, container.id || container.name))
                root.showToast("error", `Could not open logs for ${container.name}`, "");
            return;
        }

        const key = container.key;
        if (root.pendingFor(key))
            return;
        root.setPending(key, actionId);
        const accepted = GantryService.executeAction(container.runtime, container.id || container.name, actionId, (success, message) => {
            root.setPending(key, "");
            if (success)
                root.showToast("success", `${container.name} ${root.pastTense(actionId)}`, "");
            else
                root.showToast("error", `Failed to ${actionId} ${container.name}`, message);
        });

        if (!accepted) {
            root.setPending(key, "");
            root.showToast("error", `Failed to ${actionId} ${container.name}`, "runtime unavailable");
        }
    }

    function runProjectAction(project, actionId) {
        if (!project)
            return;

        if (actionId === "logs") {
            if (!GantryService.executeComposeAction(project.runtime, project.workingDir, project.configFile, "logs"))
                root.showToast("error", `Could not open logs for ${project.name}`, "");
            return;
        }

        const key = project.key;
        if (root.pendingFor(key))
            return;
        root.setPending(key, actionId);
        const accepted = GantryService.executeComposeAction(project.runtime, project.workingDir, project.configFile, actionId, (success, message) => {
            root.setPending(key, "");
            if (success)
                root.showToast("success", `${project.name} ${root.pastTense(actionId)}`, "");
            else
                root.showToast("error", `Failed to ${actionId} ${project.name}`, message);
        });

        if (!accepted) {
            root.setPending(key, "");
            root.showToast("error", `Failed to ${actionId} ${project.name}`, "runtime unavailable");
        }
    }

    // ------------------------------------------------------------------
    // Navigation
    // ------------------------------------------------------------------
    function openContainerSheet(container, fromProjectKey) {
        root.openContainerKey = container.key;
        root.openProjectKey = fromProjectKey || "";
        root.level = "container";
        root.sheetSection = "actions";
        root.selectedIndex = 0;
        root.clearToast();
    }

    function openProjectSheet(project) {
        root.openProjectKey = project.key;
        root.level = "project";
        root.sheetSection = "actions";
        root.selectedIndex = 0;
        root.clearToast();
    }

    function goBack() {
        root.clearToast();
        if (root.level === "container") {
            if (root.openProjectKey) {
                root.level = "project";
                root.sheetSection = "services";
                root.selectedIndex = Math.max(0, root.sheetServices.findIndex(c => c.key === root.openContainerKey));
            } else {
                root.level = "root";
                root.sheetSection = "actions";
                root.selectedIndex = Math.max(0, root.rootList.findIndex(c => c.key === root.openContainerKey));
            }
            root.openContainerKey = "";
            return;
        }
        if (root.level === "project") {
            root.level = "root";
            root.sheetSection = "actions";
            root.selectedIndex = Math.max(0, root.rootList.findIndex(p => p.key === root.openProjectKey));
            root.openProjectKey = "";
        }
    }

    function goRoot() {
        root.level = "root";
        root.openProjectKey = "";
        root.openContainerKey = "";
        root.sheetSection = "actions";
        root.selectedIndex = 0;
        root.keyboardActive = false;
        root.clearToast();
    }

    function toggleView() {
        if (root.level !== "root")
            return;
        root.groupByCompose = !root.groupByCompose;
        root.pluginService?.savePluginData(GantryService.pluginId, "groupByCompose", root.groupByCompose);
        root.selectedIndex = 0;
    }

    function currentListLength() {
        if (root.level === "root")
            return root.rootList.length;
        if (root.level === "project")
            return root.sheetSection === "services" ? root.sheetServices.length : root.sheetActions.length;
        return root.sheetActions.length;
    }

    function moveSelection(delta) {
        const length = currentListLength();
        if (length === 0)
            return;
        if (!root.keyboardActive) {
            root.keyboardActive = true;
            root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, length - 1));
            return;
        }
        root.selectedIndex = Math.max(0, Math.min(root.selectedIndex + delta, length - 1));
    }

    function activateSelection() {
        root.keyboardActive = true;
        if (root.level === "root") {
            const item = root.rootList[root.selectedIndex];
            if (!item)
                return;
            if (root.groupByCompose)
                root.openProjectSheet(item);
            else
                root.openContainerSheet(item, "");
            return;
        }

        if (root.level === "project" && root.sheetSection === "services") {
            const service = root.sheetServices[root.selectedIndex];
            if (service)
                root.openContainerSheet(service, root.openProjectKey);
            return;
        }

        const action = root.sheetActions[root.selectedIndex];
        if (!action || root.sheetBlocked)
            return;
        if (root.level === "project")
            root.runProjectAction(root.openProject, action.id);
        else
            root.runContainerAction(root.openContainer, action.id);
    }

    // Keyboard selection has to drag the viewport along. ListView does not scroll
    // to currentIndex on its own with the default highlightRangeMode, and a
    // Flickable never does -- without this, selecting past the visible rows
    // navigates blind.
    function ensureItemVisible(flickable, item) {
        if (!flickable || !item)
            return;
        const top = item.mapToItem(flickable.contentItem, 0, 0).y;
        const bottom = top + item.height;
        if (top < flickable.contentY)
            flickable.contentY = top;
        else if (bottom > flickable.contentY + flickable.height)
            flickable.contentY = bottom - flickable.height;
    }

    function switchSheetSection() {
        if (root.level !== "project" || root.sheetServices.length === 0)
            return;
        root.sheetSection = root.sheetSection === "actions" ? "services" : "actions";
        root.selectedIndex = 0;
        root.keyboardActive = true;
    }

    Component.onCompleted: {
        // Singletons are lazy in QML; this is what instantiates the service.
        console.log(GantryService.pluginId, "loaded.");
    }

    // ------------------------------------------------------------------
    // Building blocks
    // ------------------------------------------------------------------
    component RuntimeBadge: Rectangle {
        id: runtimeBadge
        property string runtimeId: ""

        implicitWidth: badgeLabel.implicitWidth + 12
        implicitHeight: 16
        radius: 5
        color: Qt.rgba(root.runtimeTint(runtimeId).r, root.runtimeTint(runtimeId).g, root.runtimeTint(runtimeId).b, 0.18)

        StyledText {
            id: badgeLabel
            anchors.centerIn: parent
            text: runtimeBadge.runtimeId
            font.family: "monospace"
            font.pixelSize: 10
            color: root.runtimeTint(runtimeBadge.runtimeId)
        }
    }

    component ChipPill: Rectangle {
        id: chipPill
        property string label: ""
        property color tint: Theme.primary

        implicitWidth: chipLabel.implicitWidth + 16
        implicitHeight: 20
        radius: 999
        color: Qt.rgba(tint.r, tint.g, tint.b, 0.15)

        StyledText {
            id: chipLabel
            anchors.centerIn: parent
            text: chipPill.label
            font.family: "monospace"
            font.pixelSize: 11
            color: chipPill.tint
        }
    }

    component StateChip: Rectangle {
        id: stateChip
        property string label: ""
        property color tint: Theme.primary

        implicitWidth: chipRow.implicitWidth + 16
        implicitHeight: 22
        radius: 999
        color: Qt.rgba(tint.r, tint.g, tint.b, 0.18)

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6

            Rectangle {
                width: 7
                height: 7
                radius: 3.5
                color: stateChip.tint
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: stateChip.label
                font.pixelSize: 11
                color: stateChip.tint
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    component MetaField: Column {
        id: metaField
        property string label: ""
        spacing: 3

        StyledText {
            text: metaField.label.toUpperCase()
            font.pixelSize: 10
            font.letterSpacing: 0.08 * 10
            color: Theme.surfaceVariantText
        }
    }

    component ListRow: Rectangle {
        id: listRow
        property bool isSelected: false
        signal activated

        width: parent ? parent.width : 0
        height: 42
        radius: 14
        color: (isSelected || rowMouse.containsMouse) ? Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency) : "transparent"

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.keyboardActive = false;
                listRow.activated();
            }
        }
    }

    component ActionRow: Rectangle {
        id: actionRow
        property string label: ""
        property string icon: ""
        property bool isSelected: false
        property bool busy: false
        property bool blocked: false
        signal activated

        width: parent ? parent.width : 0
        height: 44
        radius: 14
        opacity: blocked && !busy ? 0.5 : 1
        color: (isSelected || actionMouse.containsMouse) && !blocked ? Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency) : "transparent"

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12

            Item {
                width: 20
                height: 20
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    name: actionRow.icon
                    size: 20
                    color: Theme.surfaceText
                    visible: !actionRow.busy
                }

                DankSpinner {
                    anchors.centerIn: parent
                    size: 18
                    color: Theme.primary
                    visible: actionRow.busy
                    running: actionRow.busy
                }
            }

            StyledText {
                text: actionRow.label
                font.pixelSize: 14
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !actionRow.blocked && !actionRow.busy
            cursorShape: actionRow.busy ? Qt.BusyCursor : actionRow.blocked ? Qt.ForbiddenCursor : Qt.PointingHandCursor
            onClicked: {
                root.keyboardActive = false;
                actionRow.activated();
            }
        }
    }

    component EmptyState: Column {
        id: emptyState
        property string icon: "deployed_code"
        property string title: ""
        property string subtitle: ""
        property color iconColor: Theme.surfaceVariantText

        width: parent ? parent.width : 0
        topPadding: 32
        bottomPadding: 32
        spacing: 10

        DankIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: emptyState.icon
            size: 34
            color: emptyState.iconColor
        }

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: emptyState.title
            font.pixelSize: 14
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: emptyState.width - 40
            anchors.horizontalCenter: parent.horizontalCenter
            text: emptyState.subtitle
            font.pixelSize: 12
            color: Theme.surfaceVariantText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }

    component SheetHeader: Item {
        id: sheetHeader
        property string title: ""
        property string subtitle: ""
        property string badgeRuntime: ""
        property string chipLabel: ""
        property color chipColor: Theme.primary

        width: parent ? parent.width : 0
        height: 40

        Rectangle {
            id: backButton
            width: 36
            height: 36
            radius: 12
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: backMouse.containsMouse ? Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency) : Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)

            DankIcon {
                anchors.centerIn: parent
                name: "arrow_back"
                size: 20
                color: Theme.surfaceText
            }

            MouseArea {
                id: backMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goBack()
            }
        }

        StateChip {
            id: headerChip
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: sheetHeader.chipLabel !== ""
            label: sheetHeader.chipLabel
            tint: sheetHeader.chipColor
        }

        Column {
            anchors.left: backButton.right
            anchors.leftMargin: 12
            anchors.right: headerChip.visible ? headerChip.left : parent.right
            anchors.rightMargin: headerChip.visible ? 10 : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Row {
                width: parent.width
                spacing: 6

                StyledText {
                    text: sheetHeader.title
                    font.pixelSize: 15
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - (headerBadge.visible ? headerBadge.width + 6 : 0))
                }

                RuntimeBadge {
                    id: headerBadge
                    runtimeId: sheetHeader.badgeRuntime
                    visible: sheetHeader.badgeRuntime !== ""
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                text: sheetHeader.subtitle
                font.family: "monospace"
                font.pixelSize: 11
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                width: parent.width
                visible: text !== ""
            }
        }
    }

    // ------------------------------------------------------------------
    // Bar pill
    // ------------------------------------------------------------------
    component TrayIcon: DankNFIcon {
        name: "docker"
        size: root.iconSize
        color: (!root.anyRuntimeAvailable || globalRunningContainers.value === 0) ? Theme.surfaceVariantText : (Theme.widgetIconColor || Theme.surfaceText)
        opacity: (!root.anyRuntimeAvailable || globalRunningContainers.value === 0) ? 0.6 : 1
    }

    component TrayCount: StyledText {
        text: globalRunningContainers.value.toString()
        font.family: "monospace"
        font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale)
        color: Theme.widgetTextColor || Theme.surfaceText
        visible: root.anyRuntimeAvailable && globalRunningContainers.value > 0
    }

    horizontalBarPill: Row {
        spacing: Theme.spacingXS

        TrayIcon {
            anchors.verticalCenter: parent.verticalCenter
        }

        TrayCount {
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    verticalBarPill: Column {
        spacing: Theme.spacingXS

        TrayIcon {
            anchors.horizontalCenter: parent.horizontalCenter
        }

        TrayCount {
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    // ------------------------------------------------------------------
    // Popout
    // ------------------------------------------------------------------
    popoutContent: Component {
        FocusScope {
            id: popout
            focus: true

            // PluginPopout rebinds its content height to this item's
            // implicitHeight, so a FocusScope without one collapses to zero and
            // the popup opens empty.
            implicitWidth: root.popoutWidth
            implicitHeight: root.popoutHeight

            property var parentPopout: null

            Connections {
                target: popout.parentPopout
                function onOpened() {
                    root.goRoot();
                    Qt.callLater(() => popout.forceActiveFocus());
                }
            }

            Keys.onPressed: event => {
                const ctrl = event.modifiers & Qt.ControlModifier;
                if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
                    root.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
                    root.moveSelection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.activateSelection();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left) {
                    root.goBack();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    root.closePopout();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Tab) {
                    root.switchSheetSection();
                    event.accepted = true;
                } else if (event.key === Qt.Key_V && root.level === "root") {
                    root.toggleView();
                    event.accepted = true;
                }
            }

            Column {
                id: popoutColumn
                x: 14
                y: 14
                width: popout.width - 28
                spacing: 12

                // ---------- segmented control (root only) ----------
                Rectangle {
                    width: parent.width
                    height: 34
                    radius: 999
                    color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
                    visible: root.level === "root" && root.anyRuntimeAvailable

                    Rectangle {
                        width: parent.width / 2
                        height: parent.height - 4
                        x: root.groupByCompose ? parent.width / 2 : 2
                        y: 2
                        radius: 999
                        color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.22)

                        Behavior on x {
                            NumberAnimation {
                                duration: Theme.expressiveDurations["expressiveFastSpatial"] ?? 250
                                easing.type: Theme.standardEasing
                            }
                        }
                    }

                    Row {
                        anchors.fill: parent

                        Repeater {
                            model: [
                                {
                                    label: "Containers",
                                    compose: false
                                },
                                {
                                    label: "Compose",
                                    compose: true
                                }
                            ]

                            Item {
                                required property var modelData
                                width: parent.width / 2
                                height: parent.height

                                StyledText {
                                    anchors.centerIn: parent
                                    text: parent.modelData.label
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    color: root.groupByCompose === parent.modelData.compose ? Theme.primary : Theme.surfaceVariantText
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (root.groupByCompose !== parent.modelData.compose)
                                            root.toggleView();
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- sheet header ----------
                SheetHeader {
                    visible: root.level === "container"
                    title: root.openContainer?.name || ""
                    subtitle: root.openContainer?.image || ""
                    badgeRuntime: (root.showBadges && root.openContainer) ? root.openContainer.runtime : ""
                    chipLabel: {
                        const c = root.openContainer;
                        if (!c)
                            return "";
                        return c.health ? `${c.state} · ${c.health}` : c.state;
                    }
                    chipColor: root.stateColor(root.openContainer)
                }

                SheetHeader {
                    visible: root.level === "project"
                    title: root.openProject?.name || ""
                    subtitle: root.openProject ? `${root.openProject.runningCount}/${root.openProject.totalCount} running` : ""
                    badgeRuntime: (root.openProject && root.projectShowsBadge(root.openProject)) ? root.openProject.runtime : ""
                }

                // ---------- partially-down banner ----------
                Rectangle {
                    width: parent.width
                    height: 34
                    radius: 14
                    visible: root.partiallyDown
                    color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.16)

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        DankIcon {
                            name: "warning"
                            size: 18
                            color: Theme.warning
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: `${root.downRuntimeIds.join(", ")} unavailable — showing ${root.availableRuntimeIds.join(", ")} only`
                            font.pixelSize: 12
                            color: Theme.warning
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // ---------- body ----------
                Item {
                    id: bodyArea
                    width: parent.width
                    // Derived from root state, never from popoutColumn's own
                    // height -- that would be a binding loop through
                    // implicitHeight.
                    height: Math.max(0, root.popoutHeight - 28 - y)

                    // no runtime at all
                    EmptyState {
                        anchors.centerIn: parent
                        visible: !root.anyRuntimeAvailable
                        icon: "power_off"
                        iconColor: Theme.error
                        title: "No container runtime available"
                        subtitle: root.checkedRuntimeCount > 1 ? `Neither ${Object.keys(globalRuntimeAvailable.value || {}).join(" nor ")} responded.` : "No runtime responded."
                    }

                    // Root lists are two separate views on purpose. Sharing one
                    // delegate meant the project row's bindings were evaluated
                    // against container data, and vice versa.
                    DankListView {
                        id: containerListView
                        anchors.fill: parent

                        Connections {
                            target: root
                            function onSelectedIndexChanged() {
                                if (root.keyboardActive && containerListView.visible)
                                    Qt.callLater(() => containerListView.positionViewAtIndex(root.selectedIndex, ListView.Contain));
                            }
                        }
                        visible: root.anyRuntimeAvailable && root.level === "root" && !root.groupByCompose && root.rootList.length > 0
                        spacing: 2
                        clip: true
                        model: root.groupByCompose ? [] : root.rootList
                        currentIndex: root.keyboardActive ? root.selectedIndex : -1

                        delegate: ListRow {
                            id: containerRow
                            required property var modelData
                            required property int index

                            width: containerListView.width
                            isSelected: root.keyboardActive && root.selectedIndex === index
                            opacity: (modelData.isRunning || modelData.isPaused) ? 1 : 0.6
                            onActivated: root.openContainerSheet(modelData, "")

                            Rectangle {
                                id: stateDot
                                width: 8
                                height: 8
                                radius: 4
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                color: root.stateColor(containerRow.modelData)
                            }

                            Row {
                                anchors.left: stateDot.right
                                anchors.leftMargin: 10
                                anchors.right: containerChevron.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                StyledText {
                                    text: containerRow.modelData.name
                                    font.pixelSize: 14
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                    wrapMode: Text.NoWrap
                                    maximumLineCount: 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    // The name is the last thing to give up space.
                                    width: Math.min(implicitWidth, Math.max(60, parent.width - (rowBadge.visible ? rowBadge.width + 6 : 0) - 70))
                                }

                                RuntimeBadge {
                                    id: rowBadge
                                    runtimeId: containerRow.modelData.runtime
                                    visible: root.showBadges
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: root.secondaryText(containerRow.modelData)
                                    font.family: "monospace"
                                    font.pixelSize: 11
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    wrapMode: Text.NoWrap
                                    maximumLineCount: 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, parent.width - x)
                                }
                            }

                            DankIcon {
                                id: containerChevron
                                name: "chevron_right"
                                size: 20
                                color: Theme.surfaceVariantText
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    DankListView {
                        id: projectListView
                        anchors.fill: parent

                        Connections {
                            target: root
                            function onSelectedIndexChanged() {
                                if (root.keyboardActive && projectListView.visible)
                                    Qt.callLater(() => projectListView.positionViewAtIndex(root.selectedIndex, ListView.Contain));
                            }
                        }
                        visible: root.anyRuntimeAvailable && root.level === "root" && root.groupByCompose && root.rootList.length > 0
                        spacing: 2
                        clip: true
                        model: root.groupByCompose ? root.rootList : []
                        currentIndex: root.keyboardActive ? root.selectedIndex : -1

                        delegate: ListRow {
                            id: projectRow
                            required property var modelData
                            required property int index

                            width: projectListView.width
                            isSelected: root.keyboardActive && root.selectedIndex === index
                            opacity: modelData.runningCount > 0 ? 1 : 0.6
                            onActivated: root.openProjectSheet(modelData)

                            DankIcon {
                                id: projectIcon
                                name: "account_tree"
                                size: 20
                                color: projectRow.modelData.runningCount > 0 ? Theme.primary : Theme.surfaceVariantText
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                anchors.left: projectIcon.right
                                anchors.leftMargin: 10
                                anchors.right: projectChevron.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                Row {
                                    spacing: 6

                                    StyledText {
                                        text: projectRow.modelData.name
                                        font.pixelSize: 14
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                        maximumLineCount: 1
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    RuntimeBadge {
                                        runtimeId: projectRow.modelData.runtime
                                        visible: root.projectShowsBadge(projectRow.modelData)
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                StyledText {
                                    text: `${projectRow.modelData.runningCount}/${projectRow.modelData.totalCount} running · ${projectRow.modelData.containers.length} service${projectRow.modelData.containers.length !== 1 ? "s" : ""}`
                                    font.family: "monospace"
                                    font.pixelSize: 11
                                    color: Theme.surfaceVariantText
                                }
                            }

                            DankIcon {
                                id: projectChevron
                                name: "chevron_right"
                                size: 20
                                color: Theme.surfaceVariantText
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    // empty root list
                    EmptyState {
                        anchors.centerIn: parent
                        visible: root.anyRuntimeAvailable && root.level === "root" && root.rootList.length === 0
                        icon: root.groupByCompose ? "account_tree" : "deployed_code"
                        title: root.groupByCompose ? "No compose projects" : "No containers"
                        subtitle: `${root.availableRuntimeIds.join(" and ")} ${root.availableRuntimeIds.length > 1 ? "are" : "is"} running but ${root.availableRuntimeIds.length > 1 ? "have" : "has"} nothing to show.`
                    }

                    // ---------- container sheet ----------
                    Flickable {
                        id: containerSheetFlick
                        anchors.fill: parent
                        visible: root.level === "container" && root.openContainer !== null
                        contentHeight: containerSheet.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: containerSheet
                            width: parent.width
                            spacing: 12

                            // metadata card
                            Rectangle {
                                width: parent.width
                                radius: 16
                                color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
                                height: metaGrid.height + 24
                                visible: metaGrid.children.length > 0

                                Column {
                                    id: metaGrid
                                    x: 12
                                    y: 12
                                    width: parent.width - 24
                                    spacing: 16

                                    // two-column pairs
                                    Grid {
                                        width: parent.width
                                        columns: 2
                                        columnSpacing: 12
                                        rowSpacing: 16

                                        MetaField {
                                            label: "Runtime"
                                            width: (parent.width - 12) / 2

                                            StyledText {
                                                text: root.openContainer?.runtime || ""
                                                font.family: "monospace"
                                                font.pixelSize: 12
                                                color: Theme.surfaceText
                                            }
                                        }

                                        MetaField {
                                            label: "Uptime"
                                            width: (parent.width - 12) / 2
                                            visible: (root.openContainer?.isRunning || root.openContainer?.isPaused) ?? false

                                            StyledText {
                                                text: {
                                                    root.nowTick;
                                                    return root.openContainer ? root.formatUptime(root.openContainer.startedAt) : "";
                                                }
                                                font.family: "monospace"
                                                font.pixelSize: 12
                                                color: Theme.surfaceText
                                            }
                                        }

                                        MetaField {
                                            label: "Project"
                                            width: (parent.width - 12) / 2
                                            visible: (root.openContainer?.composeProject || "") !== ""

                                            StyledText {
                                                text: root.openContainer?.composeProject || ""
                                                font.pixelSize: 12
                                                color: Theme.surfaceText
                                            }
                                        }

                                        MetaField {
                                            label: "Pod"
                                            width: (parent.width - 12) / 2
                                            visible: (root.openContainer?.pod || "") !== ""

                                            StyledText {
                                                text: root.openContainer?.pod || ""
                                                font.family: "monospace"
                                                font.pixelSize: 12
                                                color: Theme.surfaceText
                                            }
                                        }

                                        MetaField {
                                            label: "Restarts"
                                            width: (parent.width - 12) / 2
                                            visible: (root.openContainer?.restartCount || 0) > 0

                                            StyledText {
                                                text: String(root.openContainer?.restartCount || 0)
                                                font.family: "monospace"
                                                font.pixelSize: 12
                                                color: Theme.surfaceText
                                            }
                                        }
                                    }

                                    MetaField {
                                        label: "Ports"
                                        width: parent.width
                                        visible: (root.openContainer?.ports?.length || 0) > 0

                                        Flow {
                                            width: parent.width
                                            spacing: 6

                                            Repeater {
                                                model: root.openContainer?.ports || []

                                                ChipPill {
                                                    required property var modelData
                                                    label: `${modelData.hostPort} → ${modelData.containerPort.replace("/tcp", "").replace("/udp", "")}`
                                                }
                                            }
                                        }
                                    }

                                    MetaField {
                                        label: "Mounts"
                                        width: parent.width
                                        visible: (root.openContainer?.mounts?.length || 0) > 0

                                        Column {
                                            width: parent.width
                                            spacing: 3

                                            Repeater {
                                                model: root.openContainer?.mounts || []

                                                StyledText {
                                                    required property var modelData
                                                    width: parent.width
                                                    text: `${modelData.source} → ${modelData.destination}`
                                                    font.family: "monospace"
                                                    font.pixelSize: 11
                                                    color: Theme.surfaceText
                                                    elide: Text.ElideMiddle
                                                }
                                            }
                                        }
                                    }

                                    MetaField {
                                        label: "Networks"
                                        width: parent.width
                                        visible: (root.openContainer?.networks?.length || 0) > 0

                                        Flow {
                                            width: parent.width
                                            spacing: 6

                                            Repeater {
                                                model: root.openContainer?.networks || []

                                                ChipPill {
                                                    required property var modelData
                                                    label: modelData
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // actions
                            Column {
                                width: parent.width
                                spacing: 2

                                Repeater {
                                    model: root.sheetActions

                                    ActionRow {
                                        id: containerActionRow
                                        required property var modelData
                                        required property int index
                                        label: modelData.label
                                        icon: modelData.icon
                                        busy: root.sheetPendingAction === modelData.id
                                        blocked: root.sheetBlocked && !busy
                                        isSelected: root.keyboardActive && root.selectedIndex === index
                                        onActivated: root.runContainerAction(root.openContainer, modelData.id)
                                        onIsSelectedChanged: {
                                            if (isSelected)
                                                root.ensureItemVisible(containerSheetFlick, containerActionRow);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---------- project sheet ----------
                    Flickable {
                        id: projectSheetFlick
                        anchors.fill: parent
                        visible: root.level === "project" && root.openProject !== null
                        contentHeight: projectSheet.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: projectSheet
                            width: parent.width
                            spacing: 10

                            Column {
                                width: parent.width
                                spacing: 2

                                Repeater {
                                    model: root.sheetActions

                                    ActionRow {
                                        id: projectActionRow
                                        required property var modelData
                                        required property int index
                                        label: modelData.label
                                        icon: modelData.icon
                                        busy: root.sheetPendingAction === modelData.id
                                        blocked: root.sheetBlocked && !busy
                                        isSelected: root.keyboardActive && root.sheetSection === "actions" && root.selectedIndex === index
                                        onActivated: root.runProjectAction(root.openProject, modelData.id)
                                        onIsSelectedChanged: {
                                            if (isSelected)
                                                root.ensureItemVisible(projectSheetFlick, projectActionRow);
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outlineLight
                            }

                            StyledText {
                                x: 6
                                text: "SERVICES"
                                font.pixelSize: 10
                                font.letterSpacing: 0.08 * 10
                                color: Theme.surfaceVariantText
                            }

                            Column {
                                width: parent.width
                                spacing: 2

                                Repeater {
                                    model: root.sheetServices

                                    ListRow {
                                        id: serviceRow
                                        required property var modelData
                                        required property int index
                                        isSelected: root.keyboardActive && root.sheetSection === "services" && root.selectedIndex === index
                                        opacity: (modelData.isRunning || modelData.isPaused) ? 1 : 0.6
                                        onActivated: root.openContainerSheet(modelData, root.openProjectKey)
                                        onIsSelectedChanged: {
                                            if (isSelected)
                                                root.ensureItemVisible(projectSheetFlick, serviceRow);
                                        }

                                        Rectangle {
                                            id: serviceDot
                                            width: 8
                                            height: 8
                                            radius: 4
                                            anchors.left: parent.left
                                            anchors.leftMargin: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: root.stateColor(serviceRow.modelData)
                                        }

                                        Column {
                                            anchors.left: serviceDot.right
                                            anchors.leftMargin: 10
                                            anchors.right: parent.right
                                            anchors.rightMargin: 32
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 1

                                            StyledText {
                                                text: root.serviceLabel(serviceRow.modelData, root.sheetServices)
                                                font.pixelSize: 14
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                                wrapMode: Text.NoWrap
                                                maximumLineCount: 1
                                                width: parent.width
                                            }

                                            StyledText {
                                                text: {
                                                    const ports = serviceRow.modelData.ports || [];
                                                    if (ports.length > 0)
                                                        return `${ports[0].hostPort} → ${ports[0].containerPort.replace("/tcp", "").replace("/udp", "")}`;
                                                    return serviceRow.modelData.image;
                                                }
                                                font.family: "monospace"
                                                font.pixelSize: 11
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                                wrapMode: Text.NoWrap
                                                maximumLineCount: 1
                                                width: parent.width
                                            }
                                        }

                                        DankIcon {
                                            name: "chevron_right"
                                            size: 20
                                            color: Theme.surfaceVariantText
                                            anchors.right: parent.right
                                            anchors.rightMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---------- toast ----------
                    Rectangle {
                        id: toast
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: toastColumn.height + 20
                        radius: 16
                        visible: root.toastKind !== ""
                        color: root.toastKind === "error" ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.22) : Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                        border.width: 1
                        border.color: root.toastKind === "error" ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.45) : Theme.outlineLight

                        Row {
                            x: 12
                            y: 10
                            width: parent.width - 24
                            spacing: 10

                            DankIcon {
                                name: root.toastKind === "error" ? "error" : "check_circle"
                                size: 18
                                color: root.toastKind === "error" ? Theme.error : Theme.primary
                            }

                            Column {
                                id: toastColumn
                                width: parent.width - 28
                                spacing: 2

                                StyledText {
                                    text: root.toastTitle
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    width: parent.width
                                    elide: Text.ElideRight
                                    wrapMode: Text.NoWrap
                                    maximumLineCount: 1
                                }

                                StyledText {
                                    text: root.toastDetail
                                    font.family: "monospace"
                                    font.pixelSize: 11
                                    color: Theme.surfaceVariantText
                                    width: parent.width
                                    visible: text !== ""
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: root.toastKind === "error"
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.clearToast()
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 460
    popoutHeight: {
        if (level !== "root")
            return 520;
        if (!anyRuntimeAvailable)
            return 240;
        if (rootList.length === 0)
            return 260;
        return Math.min(520, 28 + 34 + 12 + (partiallyDown ? 46 : 0) + rootList.length * 44);
    }
}
