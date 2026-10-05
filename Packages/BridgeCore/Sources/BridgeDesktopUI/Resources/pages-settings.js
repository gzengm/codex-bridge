(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var M = global.CodexBridgeDesktopSettingsModels;

  function group(container, title, className) {
    var section = S.section(container, title);
    if (className) section.className += " " + className;
    var stack = S.node("div", "settings-stack");
    section.appendChild(stack);
    return stack;
  }

  function create(container, page, emit, updateState) {
    S.clear(container);
    var header = S.node("div");
    container.appendChild(header);
    var content = S.node("div", "settings-content-stack");
    container.appendChild(content);
    var appUpdate = global.CodexBridgeDesktopAppUpdate
      ? global.CodexBridgeDesktopAppUpdate.createSettings(updateState, emit) : null;
    if (appUpdate) content.appendChild(appUpdate.root);
    var models = group(content, "Agent模型与权限", "page-card settings-card");
    var preferences = M.preferences(page, emit, true);
    var agents = global.CodexBridgeDesktopSettingsAgents.create(page, emit, true);
    var qoderPermissions = global.CodexBridgeDesktopSettingsQoderPermissions.create();
    models.appendChild(preferences.root);
    models.appendChild(agents.root);
    models.appendChild(qoderPermissions.root);
    var direct = global.CodexBridgeDesktopDirect.create();
    content.appendChild(direct.root);
    var safety = group(content, "GPT/Qwen的mcp插件权限与指令");
    var approvals = S.node("div");
    safety.appendChild(approvals);
    var approvalEditor = approvalCard(page, emit);
    approvals.appendChild(approvalEditor.root);
    var instructions = global.CodexBridgeDesktopSettingsInstructions.create(page, emit);
    safety.appendChild(instructions.root);
    var service = group(content, "退出 App 后继续运行服务", "page-card settings-card");
    var status = S.node("div", "page-message");
    content.appendChild(status);
    var serviceEditor = serviceCard(page, emit);
    service.appendChild(serviceEditor.root);
    var unavailable = S.node("div");
    S.empty(unavailable, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
    container.appendChild(unavailable);
    return {
      update: function (next, nextEmit, nextUpdateState) {
        content.hidden = !next;
        unavailable.hidden = !!next;
        S.pageHeader(header, next ? next.header : { title: "设置", subtitle: "正在从本机 Service 读取偏好设置。", symbol: "gearshape" });
        if (appUpdate) appUpdate.update(nextUpdateState, nextEmit);
        if (!next) return;
        direct.update(next.direct, nextEmit);
        preferences.update(next, nextEmit);
        agents.update(next, nextEmit);
        qoderPermissions.update(next, nextEmit);
        instructions.update(next, nextEmit);
        approvalEditor.update(next, nextEmit);
        serviceEditor.update(next, nextEmit);
        status.textContent = next.statusMessage || "";
        status.hidden = !next.statusMessage;
      }
    };
  }

  function render(page, emit, updateState) {
    var container = document.getElementById("settings-content");
    if (!container.__settingsEditor && !page) {
      S.empty(container, "设置页暂不可用", "连接本机 Service 后，可以配置模型、安全审批与后台服务。");
      return;
    }
    if (!container.__settingsEditor) container.__settingsEditor = create(container, page, emit, updateState);
    container.__settingsEditor.update(page, emit, updateState);
  }

  function approvalCard(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "安全审批策略"));
    var pendingFullAccess = false;
    var direct = S.selectField("Direct 操作", page.directApprovalMode, S.choices(page.directApprovalMode, page.directApprovalOptions), function (value) {
      pendingFullAccess = value === "full-access";
      if (!pendingFullAccess) context.emit("setDirectApprovalMode", { mode: value });
      updateFullAccess();
    }, "");
    var fullAccess = S.node("div", "settings-subsection");
    var fullProject = S.selectField("完全访问项目", page.directFullAccessProjectID || "", [], function () {
      updateFullAccess();
    }, "");
    fullAccess.appendChild(fullProject.wrapper);
    var fileWriteStatus = S.node("p", "hint");
    fullAccess.appendChild(fileWriteStatus);
    fullAccess.appendChild(S.node("p", "hint",
      "仅选中项目的普通已登记或内置安全 Direct 命令、项目内文件创建和修改免审批，支持无人值守；删除、移动、撤销、版本控制元数据文件、高风险及未登记命令仍需批准。文件操作保留路径和版本校验。网络已允许时，命令以当前用户权限运行，无 Bridge 进程沙箱，可访问该用户能够访问的本机文件；网络拒绝时仍使用网络隔离。命令黑名单、项目权限及外层平台限制仍生效。"));
    var enableFullAccess = S.button("确认启用此项目完全访问", null, {}, null, "small", true);
    enableFullAccess.addEventListener("click", function () {
      if (enableFullAccess.disabled) return;
      var projectID = fullProject.control.value;
      var project = S.safeArray(context.page.directFullAccessProjectOptions).find(function (item) {
        return item.id === projectID;
      });
      if (!project) return;
      if (!global.confirm("为项目“" + project.title + "”启用完全访问？\n\n已登记普通命令、内置安全调用，以及项目内文件创建、修改和仅含新增/修改的补丁免逐次询问，支持无人值守。删除、移动、撤销、版本控制元数据文件、高风险及未登记命令仍需批准。项目外路径、符号链接逃逸和文件版本冲突仍会被拒绝。网络已允许时，它们以当前用户权限运行，能够读写该用户可访问的本机文件、执行程序并访问网络。网络拒绝、命令黑名单和项目权限仍强制执行；其他项目及 Agent 权限不变；云端工具和平台自身的审批规则仍生效。")) {
        pendingFullAccess = false;
        direct.control.value = context.page.directApprovalMode;
        fullProject.control.value = context.page.directFullAccessProjectID || "";
        updateFullAccess();
        return;
      }
      pendingFullAccess = false;
      context.emit("setDirectApprovalMode", { mode: "full-access", projectID: projectID, confirmed: true, fileWritesConfirmed: true });
    });
    fullAccess.appendChild(enableFullAccess);
    function updateFullAccess() {
      fullAccess.hidden = direct.control.value !== "full-access";
      fullProject.control.disabled = !context.page.canSaveApprovalModes;
      var savedFileWrites = context.page.directApprovalMode === "full-access"
        && context.page.directFullAccessProjectID === fullProject.control.value
        && context.page.directFullAccessFileWritesAllowed === true;
      fileWriteStatus.textContent = savedFileWrites
        ? "此项目内创建和修改文件已免逐次审批；删除、移动和版本控制元数据文件仍需批准。"
        : "此项目的文件免审批尚未开启；确认启用后可无人值守创建和修改文件。";
      enableFullAccess.disabled = !context.page.canSaveApprovalModes
        || !fullProject.control.value || savedFileWrites;
    }
    var task = S.selectField("远程任务启动", page.taskStartApprovalMode, S.choices(page.taskStartApprovalMode, page.taskStartApprovalOptions), function (value) {
      context.emit("setTaskStartApprovalMode", { mode: value });
    }, "");
    card.appendChild(direct.wrapper);
    card.appendChild(fullAccess);
    card.appendChild(task.wrapper);
    card.appendChild(S.node("p", "hint", "策略仍由本机 Service 和项目权限强制执行。"));
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      D.selectOptions(direct.control, S.choices(next.directApprovalMode, next.directApprovalOptions));
      D.selectOptions(task.control, S.choices(next.taskStartApprovalMode, next.taskStartApprovalOptions));
      var projectValue = pendingFullAccess || direct.control.value === "full-access"
        ? fullProject.control.value : next.directFullAccessProjectID || "";
      D.selectOptions(fullProject.control, [{ id: "", title: "请选择项目" }]
        .concat(S.safeArray(next.directFullAccessProjectOptions)));
      fullProject.control.value = projectValue || next.directFullAccessProjectID || "";
      direct.control.value = pendingFullAccess ? "full-access" : next.directApprovalMode || "";
      updateFullAccess();
      task.control.value = next.taskStartApprovalMode || "";
      direct.control.disabled = !next.canSaveApprovalModes;
      task.control.disabled = !next.canSaveApprovalModes;
    }
    update(page, emit);
    return { root: card, update: update };
  }

  function serviceCard(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("div", "settings-subsection");
    var description = S.node("p", "hint");
    var platform = S.node("p", "hint");
    card.appendChild(description);
    card.appendChild(platform);
    var keepRow = S.node("div", "check-field");
    var keep = S.node("button", "switch-toggle");
    keep.type = "button";
    keep.value = page.keepServiceRunningAfterExit ? "true" : "false";
    keep.setAttribute("role", "switch");
    keep.setAttribute("aria-label", "退出 App 后继续运行");
    var thumb = S.node("span", "switch-thumb");
    thumb.setAttribute("aria-hidden", "true");
    keep.appendChild(thumb);
    keepRow.appendChild(keep);
    keepRow.appendChild(S.node("span", null, "退出 App 后继续运行"));
    var keepDraft = D.bind({ keep: keep });
    function updateSwitch() {
      keep.className = "switch-toggle" + (keep.value === "true" ? " is-active" : "");
      keep.setAttribute("aria-checked", keep.value);
    }
    keep.addEventListener("click", function () {
      keep.value = keep.value === "true" ? "false" : "true";
      updateSwitch();
      context.emit("setKeepServiceRunning", { keepServiceRunningAfterExit: keep.value === "true" });
    });
    card.appendChild(keepRow);
    var badge = S.badge("未注册", "warning");
    card.appendChild(badge);
    var serviceStatus = S.node("p", "hint");
    card.appendChild(serviceStatus);
    var actions = S.node("div", "form-actions");
    card.appendChild(actions);
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      description.textContent = next.serviceDescription
        || "开启后，即使退出 App，仍可通过 ChatGPT 的 Codex Bridge 插件远程使用本机。请配置好客户端与项目权限；需要无人值守运行时，将相关审批策略设为“自动批准”。";
      platform.textContent = "平台：" + (next.servicePlatform || "未知");
      keepDraft.update({ keep: next.keepServiceRunningAfterExit ? "true" : "false" });
      updateSwitch();
      var needsAttention = next.serviceStatus
        ? next.serviceStatus !== "enabled" : !next.serviceRegistered;
      badge.textContent = next.serviceStatusTitle || (next.serviceRegistered ? "已注册" : "未注册");
      badge.className = "status-badge " + serviceTone(next);
      badge.hidden = !needsAttention;
      serviceStatus.textContent = next.serviceStatusMessage || "";
      serviceStatus.hidden = !needsAttention || !next.serviceStatusMessage;
      S.clear(actions);
      var availableActions = next.serviceStatus === "requires_approval"
        && Array.isArray(next.serviceActions) ? next.serviceActions : [];
      availableActions.forEach(function (action) {
        if (!action || action.command !== "openSystemSettings" || !action.title) return;
        var control = S.button(action.title, null, {}, null, "small", false);
        control.addEventListener("click", function () {
          context.emit(action.command, {});
        });
        actions.appendChild(control);
      });
      actions.hidden = actions.children.length === 0;
    }
    update(page, emit);
    return { root: card, update: update };
  }

  function serviceTone(page) {
    if (page.serviceStatusTone) return page.serviceStatusTone;
    if (page.serviceStatus === "not_found") return "error";
    if (page.serviceStatus === "requires_approval") return "warning";
    return page.serviceRegistered ? "success" : "warning";
  }

  global.CodexBridgeDesktopSettingsPage = { render: render };
}(window));
