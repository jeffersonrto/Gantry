pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Item {
    id: root

    readonly property var defaults: ({
            debounceDelay: 300,
            runtimes: [
                {
                    id: "docker",
                    label: "Docker",
                    binary: "docker",
                    enabled: true
                },
                {
                    id: "podman",
                    label: "Podman",
                    binary: "podman",
                    enabled: true
                }
            ],
            terminalApp: "alacritty --hold",
            shellPath: "/bin/sh",
            pollingInterval: 0
        })

    readonly property string pluginId: "gantry"

    property bool systemdRunAvailable: false
    property bool dockerAvailable: false
    property int debounceDelay: defaults.debounceDelay
    property var runtimes: defaults.runtimes
    property string terminalApp: defaults.terminalApp
    property string shellPath: defaults.shellPath
    property int pollingInterval: defaults.pollingInterval

    readonly property var enabledRuntimes: runtimes.filter(rt => rt.enabled)

    // Transitional: the collection and action code still drives a single binary.
    // Phases 2-5 replace every use of this with per-runtime routing.
    readonly property string primaryBinary: enabledRuntimes.length > 0 ? enabledRuntimes[0].binary : ""

    // Settings are user-editable JSON; a half-written entry must not poison the
    // rest of the list, so every field falls back to a sane value.
    function normalizeRuntimes(list) {
        if (!Array.isArray(list))
            return defaults.runtimes;

        const normalized = list.filter(rt => rt && rt.id).map(rt => ({
                    id: String(rt.id),
                    label: rt.label ? String(rt.label) : String(rt.id),
                    binary: rt.binary ? String(rt.binary) : String(rt.id),
                    enabled: rt.enabled !== false
                }));

        return normalized.length > 0 ? normalized : defaults.runtimes;
    }

    function loadSettings() {
        const load = key => PluginService.loadPluginData(pluginId, key) || defaults[key];
        debounceDelay = load("debounceDelay");
        runtimes = normalizeRuntimes(load("runtimes"));
        terminalApp = load("terminalApp");
        shellPath = load("shellPath");
        pollingInterval = load("pollingInterval");

        refresh();
    }

    Component.onCompleted: {
        loadSettings();
        initialize();
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pluginId) {
            if (pluginId === root.pluginId) {
                loadSettings();
            }
        }
    }

    function getDockerEventCommand() {
        return [primaryBinary, "events", "--format", "json", "--filter", "type=container"];
    }

    onRuntimesChanged: {
        eventsProcess.running = false;
        eventsProcess.command = getDockerEventCommand();
        eventsProcess.running = true;
    }

    property var debounceTimer: Timer {
        interval: root.debounceDelay
        running: false
        repeat: false
        onTriggered: fetchContainers()
    }

    property var eventsProcess: Process {
        command: getDockerEventCommand()
        running: false

        stdout: SplitParser {
            onRead: data => {
                try {
                    const event = JSON.parse(data);
                    const action = event.Status || event.status;

                    if (["start", "stop", "die", "died", "kill", "restart", "pause", "unpause", "create", "destroy", "remove", "cleanup"].includes(action)) {
                        console.log(`Gantry: Container event detected - ${action}`);
                        debounceTimer.restart();
                    }
                } catch (e) {
                    console.error("Gantry: Failed to parse docker event:", e, data);
                }
            }
        }

        onRunningChanged: {
            if (!running) {
                console.log("Gantry: Docker events process not running");
                restartTimer.start();
            }
        }
    }

    property var restartTimer: Timer {
        interval: 5000
        running: false
        repeat: false
        onTriggered: {
            if (dockerAvailable) {
                console.log("Gantry: Attempting to restart events listener...");
                eventsProcess.running = true;
            }
        }
    }

    property var pollingTimer: Timer {
        interval: root.pollingInterval
        running: root.dockerAvailable && root.pollingInterval > 0
        repeat: true
        onTriggered: {
            console.log("Gantry: Polling for container state updates");
            fetchContainers();
        }
    }

    function initialize() {
        Proc.runCommand(`${pluginId}.systemdRunCheck`, ["which", "systemd-run"], (stdout, exitCode) => {
            systemdRunAvailable = exitCode === 0;
        }, 100);

        refresh();

        eventsProcess.running = true;
    }

    function refresh() {
        Proc.runCommand(`${pluginId}.dockerCheck`, [primaryBinary, "info"], (stdout, exitCode) => {
            root.dockerAvailable = exitCode === 0;
            PluginService.setGlobalVar("gantry", "dockerAvailable", dockerAvailable);
            if (dockerAvailable) {
                fetchContainers();
            } else {
                updateContainers();
            }
        }, 100);
    }

    function fetchContainers() {
        Proc.runCommand(`${pluginId}.dockerInspect`, ["sh", "-c", `${primaryBinary} container inspect $(${primaryBinary} container ls -aq)`], (stdout, exitCode) => {
            if (exitCode === 0) {
                try {
                    const containers = JSON.parse(stdout).map(container => {
                        try {
                            const labels = container.Config?.Labels || {};
                            const state = container.State?.Status || "";
                            const startedAt = new Date(container.State?.StartedAt || 0).getTime();
                            const finishedAt = new Date(container.State?.FinishedAt || 0).getTime();
                            const lastActivity = Math.max(startedAt, finishedAt);
                            
                            const ports = [];
                            const portBindings = container.NetworkSettings?.Ports || {};
                            for (const [containerPort, hostBindings] of Object.entries(portBindings)) {
                                if (hostBindings && hostBindings.length > 0) {
                                    hostBindings.forEach(binding => {
                                        const hostPort = binding.HostPort;
                                        const hostIp = binding.HostIp || "0.0.0.0";
                                        if (hostPort) {
                                            ports.push({
                                                containerPort: containerPort,
                                                hostPort: hostPort,
                                                hostIp: hostIp
                                            });
                                        }
                                    });
                                }
                            }

                            return {
                                id: container.Id || "",
                                name: container.Name?.replace(/^\//, "") || "",
                                status: `${state.charAt(0).toUpperCase() + state.slice(1)}`,
                                state: state,
                                image: container.Config?.Image || container.ImageName || "",
                                isRunning: container.State?.Running || false,
                                isPaused: container.State?.Paused || false,
                                created: container.Created || "",
                                lastActivity: lastActivity,
                                ports: ports,
                                composeProject: labels["com.docker.compose.project"] || labels["io.podman.compose.project"] || "",
                                composeService: labels["com.docker.compose.service"] || labels["io.podman.compose.service"] || "",
                                composeWorkingDir: labels["com.docker.compose.project.working_dir"] || "",
                                composeConfigFiles: labels["com.docker.compose.project.config_files"] || "compose.yaml"
                            };
                        } catch (e) {
                            console.error("Gantry: Failed to parse container data:", e, container);
                            return null;
                        }
                    }).filter(c => c !== null).sort((a, b) => {
                        const priority = {
                            running: 1,
                            paused: 2,
                            default: 3
                        };
                        const aPriority = priority[a.state] || priority.default;
                        const bPriority = priority[b.state] || priority.default;
                        if (aPriority !== bPriority)
                            return aPriority - bPriority;
                        if (a.lastActivity !== b.lastActivity)
                            return b.lastActivity - a.lastActivity;
                        return a.name.localeCompare(b.name);
                    });

                    const projectMap = {};
                    containers.forEach(container => {
                        if (container.composeProject) {
                            if (!projectMap[container.composeProject]) {
                                projectMap[container.composeProject] = {
                                    name: container.composeProject,
                                    containers: [],
                                    runningCount: 0,
                                    totalCount: 0,
                                    workingDir: container.composeWorkingDir,
                                    configFile: container.composeConfigFiles
                                };
                            }
                            projectMap[container.composeProject].containers.push(container);
                            projectMap[container.composeProject].totalCount++;
                            if (container.isRunning) {
                                projectMap[container.composeProject].runningCount++;
                            }
                        }
                    });

                    updateContainers(containers, containers.filter(c => c.isRunning).length, Object.values(projectMap).sort((a, b) => {
                        if (a.runningCount !== b.runningCount)
                            return b.runningCount - a.runningCount;
                        return a.name.localeCompare(b.name);
                    }));
                } catch (e) {
                    console.error("Gantry: Failed to parse docker inspect output:", e);
                    updateContainers();
                }
            } else {
                updateContainers();
            }
        }, 100);
    }

    function updateContainers(containers = [], runningContainers = 0, composeProjects = []) {
        PluginService.setGlobalVar(pluginId, "containers", containers);
        PluginService.setGlobalVar(pluginId, "runningContainers", runningContainers);
        PluginService.setGlobalVar(pluginId, "composeProjects", composeProjects);
    }

    function executeAction(containerId, action) {
        const commands = {
            start: [primaryBinary, "start", containerId],
            stop: [primaryBinary, "stop", containerId],
            restart: [primaryBinary, "restart", containerId],
            pause: [primaryBinary, "pause", containerId],
            unpause: [primaryBinary, "unpause", containerId]
        };

        if (commands[action]) {
            const cmdArray = systemdRunAvailable ? ["systemd-run", "--user", "--scope", "--", ...commands[action]] : commands[action];
            Quickshell.execDetached(cmdArray);
            Qt.callLater(() => {
                root.refresh();
            });
            return true;
        }
        return false;
    }

    function executeComposeAction(workingDir, configFile, action) {
        if (!workingDir) {
            console.error("Gantry: Cannot execute compose action without working directory");
            return false;
        }

        const composeCommands = {
            up: [primaryBinary, "compose", "-f", configFile, "up", "-d"],
            down: [primaryBinary, "compose", "-f", configFile, "down"],
            restart: [primaryBinary, "compose", "-f", configFile, "restart"],
            stop: [primaryBinary, "compose", "-f", configFile, "stop"],
            start: [primaryBinary, "compose", "-f", configFile, "start"],
            pull: [primaryBinary, "compose", "-f", configFile, "pull"],
            logs: null
        };

        if (action === "logs") {
            const cmd = `cd "${workingDir}" && ${primaryBinary} compose -f ${configFile} logs -f`;
            Quickshell.execDetached(["sh", "-c", `${terminalApp} -e sh -c '${cmd}'`]);
            return true;
        }

        if (composeCommands[action]) {
            const cmd = ["sh", "-c", `cd "${workingDir}" && ${composeCommands[action].join(" ")}`];
            const cmdArray = systemdRunAvailable ? ["systemd-run", "--user", "--scope", "--", ...cmd] : cmd;
            Quickshell.execDetached(cmdArray);
            Qt.callLater(() => {
                root.refresh();
            });
            return true;
        }
        return false;
    }

    function openLogs(containerId) {
        Quickshell.execDetached(["sh", "-c", terminalApp + " -e " + primaryBinary + " logs -f " + containerId]);
    }

    function openExec(containerId) {
        Quickshell.execDetached(["sh", "-c", terminalApp + " -e " + primaryBinary + " exec -it " + containerId + " " + shellPath]);
    }
}
