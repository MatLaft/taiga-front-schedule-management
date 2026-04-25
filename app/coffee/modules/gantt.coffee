###
# This source code is licensed under the terms of the
# GNU Affero General Public License found in the LICENSE file in
# the root directory of this source tree.
#
# Copyright (c) 2021-present Kaleidos INC
###

taiga = @.taiga
mixOf = @.taiga.mixOf
bindMethods = @.taiga.bindMethods
getDefaulColorList = taiga.getDefaulColorList

module = angular.module("taigaGantt", [])

class GanttController extends mixOf(taiga.Controller, taiga.PageMixin)
    @.$inject = [
        "$scope",
        "$q",
        "$tgRepo",
        "$tgConfirm",
        "$translate",
        "tgProjectService",
        "$tgEvents",
        "tgErrorHandlingService"
    ]

    constructor: (@scope, @q, @repo, @confirm, @translate, @projectService, @events, @errorHandlingService) ->
        bindMethods(@)

        @scope.sectionName = "PROJECT.SECTION.GANTT"
        @dayWidthRem = 2.2
        @weekWidthRem = 7
        @monthDayWidthRem = 0.35
        @weeklyColumnWidthRemMin = 4.2
        @weeklyColumnWidthRemMax = 12
        @monthlyDayWidthRemMin = 0.2
        @monthlyDayWidthRemMax = 0.8
        @timelineWidthSliderMin = 0
        @timelineWidthSliderMax = 100
        @timelineWidthSliderStep = 1

        @loading = false
        @loadingError = false
        @tree = []
        @ganttBars = []
        @timeline = @_emptyTimeline()
        @timelineStartAnchor = null
        @membersById = {}
        @rowNodesById = {}
        @savingRows = {}
        @sourceEpics = []
        @sourceUserstories = []
        @sourceTasks = []
        @sourceScheduleDependencies = []
        @colorList = getDefaulColorList()
        @activeColorMenuRowId = null
        @nodeCustomColorByRowId = {}
        @colorMenuOpenUpwardByRowId = {}
        @zoomMenuOpen = false
        @selectedZoomOption = "daily"
        @timelineWidthSliderValue = @timelineWidthSliderMin
        @barsLocked = true
        @colorPickerModeActive = false
        @barLinkModeActive = false
        @pendingBarLinkSourceRowId = null
        @barLinks = []
        @scheduleIdByRowId = {}
        @rowIdByScheduleId = {}
        @savingBarLinks = false
        @barChangeUndoStack = []
        @barChangeRedoStack = []
        @barChangeHistoryLimit = 100
        @barHistoryBusy = false
        @treeRowReorderBusy = false
        @subscriptionsInitialized = false
        @realtimeSyncInProgress = false
        @realtimeSyncPending = false
        @realtimeSyncDebounced = null

        @documentClickHandler = (event) => @onDocumentClick(event)
        angular.element(document).on("click", @documentClickHandler)
        @scope.$on "$destroy", =>
            angular.element(document).off("click", @documentClickHandler)
            @realtimeSyncDebounced?.cancel?()

        promise = @loadInitialData()
        promise.then null, @onInitialDataError.bind(@)

    loadProject: ->
        project = @projectService.project.toJS()

        @scope.projectId = project.id
        @scope.project = project
        @scope.$emit("project:loaded", project)

        @membersById = {}
        _.each(project.members or [], (member) =>
            return if !member?.id?
            @membersById["#{member.id}"] = member
        )

        return project

    loadInitialData: ->
        @loadProject()
        @initializeSubscription()
        @_restoreZoomOptionFromCookie()
        @_restoreZoomSliderStateFromCookie()
        @_syncTimelineWidthSliderValue()
        return @load()

    initializeSubscription: ->
        return if @subscriptionsInitialized
        return if !@scope.projectId
        return if !@events?

        @subscriptionsInitialized = true
        randomTimeout = taiga.randomInt(700, 1000)
        @realtimeSyncDebounced = _.debounce((=> @_queueRealtimeSyncFromEvents()), randomTimeout)

        routingKeys = [
            "changes.project.#{@scope.projectId}.epics"
            "changes.project.#{@scope.projectId}.userstories"
            "changes.project.#{@scope.projectId}.tasks"
            "changes.project.#{@scope.projectId}.schedule"
        ]

        _.each(routingKeys, (routingKey) =>
            @events.subscribe @scope, routingKey, =>
                @realtimeSyncDebounced?()
        )

    _queueRealtimeSyncFromEvents: ->
        return if !@scope.projectId

        if @realtimeSyncInProgress
            @realtimeSyncPending = true
            return

        @realtimeSyncInProgress = true

        return @_reloadGanttDataSilently().then =>
            return
        , =>
            return
        .finally =>
            @realtimeSyncInProgress = false

            if @realtimeSyncPending
                @realtimeSyncPending = false
                _.defer(=> @_queueRealtimeSyncFromEvents())

    load: ->
        return @q.when() if !@scope.projectId

        @loading = true
        @loadingError = false

        return @_reloadGanttDataSilently().then =>
            @loading = false
        , (xhr) =>
            @loading = false
            @loadingError = true

            if xhr?.status != 403 and xhr?.status != 404
                @confirm.notify("error")

            return @q.reject(xhr)

    _reloadGanttDataSilently: ->
        return @q.when() if !@scope.projectId

        promises = [
            @repo.queryMany("epics", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("userstories", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("tasks", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("schedule-dependencies", {project: @scope.projectId})
        ]

        return @q.all(promises).then (result) =>
            [epics, userstories, tasks, scheduleDependencies] = result
            @buildGanttData(
                epics or [],
                userstories or [],
                tasks or [],
                scheduleDependencies or []
            )
            @scope.$evalAsync()
            return

    buildGanttData: (epics, userstories, tasks, scheduleDependencies = @sourceScheduleDependencies) ->
        @sourceEpics = epics or []
        @sourceUserstories = userstories or []
        @sourceTasks = tasks or []
        @sourceScheduleDependencies = scheduleDependencies or []

        @timelineStartAnchor = null
        @tree = @_buildTree(@sourceEpics, @sourceUserstories, @sourceTasks)
        @_refreshComputedData()

    _refreshComputedData: ->
        _.each(@tree, (node) =>
            @_computeNodeProgress(node)
        )

        flatRows = @_flattenRows(@tree)
        @rowNodesById = {}
        _.each(flatRows, (row) =>
            @rowNodesById[row.rowId] = row
        )
        @_rebuildScheduleRowMaps(flatRows)
        @timeline = @_buildTimeline(flatRows)
        @ganttBars = @_buildBars(flatRows, @timeline)
        @_syncBarLinksFromDependencies()
        @_pruneBarLinks()

    _refreshTimelineLayoutForCurrentTree: ->
        flatRows = @_flattenRows(@tree)
        @timeline = @_buildTimeline(flatRows)
        @ganttBars = @_buildBars(flatRows, @timeline)
        @_pruneBarLinks()

    _findTreeRowLocation: (rowId, nodes = @tree, parentRow = null) ->
        return null if !rowId? or !_.isArray(nodes)

        for node, index in nodes
            continue if !node?

            if node.rowId == rowId
                return {
                    row: node
                    index: index
                    siblings: nodes
                    parentRow: parentRow
                }

            if _.isArray(node.children) and node.children.length
                childLocation = @_findTreeRowLocation(rowId, node.children, node)
                return childLocation if childLocation?

        return null

    getGanttRowReorderContext: (rowId) ->
        location = @_findTreeRowLocation(rowId)
        return null if !location?.row?

        rowType = location.row.type
        siblingRows = _.filter(location.siblings or [], (candidate) ->
            return candidate?.type == rowType
        )
        siblingRowIds = _.compact(_.map(siblingRows, (candidate) ->
            return candidate?.rowId
        ))
        rowIndex = siblingRowIds.indexOf(rowId)

        return {
            rowId: rowId
            rowType: rowType
            rowIndex: rowIndex
            parentRowId: location.parentRow?.rowId or null
            siblingRowIds: siblingRowIds
        }

    requestGanttRowReorder: (rowId, targetIndex, options = {}) ->
        notify = options.notify != false
        skipHistory = !!options.skipHistory
        return @q.when(false) if @treeRowReorderBusy

        context = @getGanttRowReorderContext(rowId)
        return @q.when(false) if !context? or !_.isArray(context.siblingRowIds)

        currentIndex = parseInt(context.rowIndex, 10)
        return @q.when(false) if isNaN(currentIndex) or currentIndex < 0

        numericTargetIndex = parseInt(targetIndex, 10)
        return @q.when(false) if isNaN(numericTargetIndex)

        maxIndex = Math.max(0, context.siblingRowIds.length - 1)
        numericTargetIndex = Math.max(0, Math.min(maxIndex, numericTargetIndex))
        return @q.when(false) if numericTargetIndex == currentIndex

        row = @rowNodesById[rowId]
        return @q.when(false) if !row?.item?
        historyEntry = @_buildRowReorderHistoryEntry(
            rowId
            currentIndex
            numericTargetIndex
            context.parentRowId
            context.rowType
        )

        itemToSave = row.item
        if _.isFunction(row.item.realClone)
            itemToSave = row.item.realClone()
            itemToSave.revert?()

        itemToSave.setAttr("position", numericTargetIndex + 1)
        @treeRowReorderBusy = true

        return @repo.save(itemToSave, true, {include_schedule: true}).then =>
            return @_reloadGanttDataSilently().then =>
                @_registerBarChangeHistoryEntry(historyEntry) if !skipHistory
                @confirm.notify("success") if notify
                return true
            , =>
                moved = @moveGanttRowWithinSiblings(rowId, numericTargetIndex)
                @_registerBarChangeHistoryEntry(historyEntry) if moved and !skipHistory
                @confirm.notify("success") if moved and notify
                return moved
        , (errorData) =>
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message) if notify
            return @q.reject(errorData)
        .finally =>
            @treeRowReorderBusy = false
            @scope.$evalAsync()

    moveGanttRowWithinSiblings: (rowId, targetIndex) ->
        location = @_findTreeRowLocation(rowId)
        return false if !location?.row? or !_.isArray(location.siblings)

        rowType = location.row.type
        siblingRows = _.filter(location.siblings, (candidate) ->
            return candidate?.type == rowType
        )
        return false if siblingRows.length < 2

        siblingRowIds = _.compact(_.map(siblingRows, (candidate) ->
            return candidate?.rowId
        ))
        currentIndex = siblingRowIds.indexOf(rowId)
        return false if currentIndex == -1

        numericTargetIndex = parseInt(targetIndex, 10)
        return false if isNaN(numericTargetIndex)
        numericTargetIndex = Math.max(0, Math.min(siblingRows.length - 1, numericTargetIndex))
        return false if numericTargetIndex == currentIndex

        reorderedSiblingRows = siblingRows.slice(0)
        movingRow = reorderedSiblingRows.splice(currentIndex, 1)[0]
        reorderedSiblingRows.splice(numericTargetIndex, 0, movingRow)

        siblingPositions = []
        _.each(location.siblings, (candidate, index) ->
            siblingPositions.push(index) if candidate?.type == rowType
        )

        _.each(siblingPositions, (position, index) ->
            location.siblings[position] = reorderedSiblingRows[index]
        )

        @_refreshComputedData()
        @scope.$evalAsync()
        return true

    _rowIdFromScheduleEntity: (entityType, entityId) ->
        normalizedType = "#{entityType or ''}".toLowerCase()
        normalizedEntityId = @_normalizeId(entityId)
        return null if !normalizedEntityId?

        rowPrefix = null
        rowPrefix = "epic" if normalizedType == "epic"
        rowPrefix = "story" if normalizedType == "userstory"
        rowPrefix = "task" if normalizedType == "task"
        return null if !rowPrefix?

        return "#{rowPrefix}-#{normalizedEntityId}"

    _rebuildScheduleRowMaps: (rows = []) ->
        @scheduleIdByRowId = {}
        @rowIdByScheduleId = {}

        _.each(rows or [], (row) =>
            return if !row?.rowId?

            scheduleId = @_normalizeId(row.item?.schedule_id)
            return if !scheduleId?

            @scheduleIdByRowId[row.rowId] = scheduleId
            @rowIdByScheduleId["#{scheduleId}"] = row.rowId
        )

    _syncBarLinksFromDependencies: ->
        links = []
        seenPairs = {}

        _.each(@sourceScheduleDependencies or [], (dependency) =>
            sourceRowId = null
            targetRowId = null

            sourceScheduleId = @_normalizeId(dependency?.from_schedule)
            targetScheduleId = @_normalizeId(dependency?.to_schedule)

            if sourceScheduleId? and targetScheduleId?
                sourceRowId = @rowIdByScheduleId["#{sourceScheduleId}"]
                targetRowId = @rowIdByScheduleId["#{targetScheduleId}"]

            if !sourceRowId?
                sourceRowId = @_rowIdFromScheduleEntity(
                    dependency?.from_entity_type
                    dependency?.from_entity_id
                )

            if !targetRowId?
                targetRowId = @_rowIdFromScheduleEntity(
                    dependency?.to_entity_type
                    dependency?.to_entity_id
                )

            return if !sourceRowId? or !targetRowId? or sourceRowId == targetRowId
            return if !@rowNodesById[sourceRowId] or !@rowNodesById[targetRowId]

            pairKey = "#{sourceRowId}|#{targetRowId}"
            return if seenPairs[pairKey]
            seenPairs[pairKey] = true

            links.push({
                id: "#{dependency.id}"
                sourceRowId: sourceRowId
                targetRowId: targetRowId
                dependencyId: dependency.id
            })
        )

        @barLinks = links

    _normalizeDateForInput: (dateValue) ->
        return null if !dateValue

        parsed = moment(dateValue)
        return dateValue if !parsed.isValid()

        return parsed.format("YYYY-MM-DD")

    _pruneBarLinks: ->
        validBarRowsById = {}

        _.each(@ganttBars or [], (bar) ->
            validBarRowsById[bar.rowId] = true if bar?.rowId?
        )

        @barLinks = _.filter(@barLinks or [], (link) ->
            return validBarRowsById[link?.sourceRowId] and validBarRowsById[link?.targetRowId]
        )

        if @pendingBarLinkSourceRowId? and !validBarRowsById[@pendingBarLinkSourceRowId]
            @pendingBarLinkSourceRowId = null

        if (@ganttBars or []).length < 2
            @barLinkModeActive = false
            @pendingBarLinkSourceRowId = null

    _getStartEditableField: (item) ->
        return "actual_start" if item?.actual_start?
        return "estimated_start"

    _permissionForType: (type) ->
        return "modify_epic" if type == "epic"
        return "modify_us" if type == "story"
        return "modify_task" if type == "task"
        return null

    _canModifyType: (type) ->
        return false if @scope.project?.archived_code

        permission = @_permissionForType(type)
        return false if !permission?

        permissions = @scope.project?.my_permissions or []
        return permissions.indexOf(permission) != -1

    _getNodeOwnColor: (row) ->
        return null if !row?
        return @_normalizeColorValue(row.item?.color) or @_normalizeColorValue(row.barColor)

    _getTargetNodeForColorChange: (row) ->
        return null if !row?.item?

        if row.type == "epic"
            return {
                row: row
                type: "epic"
                item: row.item
                saveOptions: {include_schedule: true}
            }

        if row.epicId?
            epicRow = @rowNodesById["epic-#{row.epicId}"]
            if epicRow?.item?
                return {
                    row: epicRow
                    type: "epic"
                    item: epicRow.item
                    saveOptions: {include_schedule: true}
                }

        if row.type == "story"
            return {
                row: row
                type: "story"
                item: row.item
                saveOptions: {include_schedule: true}
            }

        if row.type == "task"
            storyId = @_extractStoryId(row.item)
            storyRow = @rowNodesById["story-#{storyId}"]
            if storyRow?.item? and !storyRow.epicId?
                return {
                    row: storyRow
                    type: "story"
                    item: storyRow.item
                    saveOptions: {include_schedule: true}
                }

            return {
                row: row
                type: "task"
                item: row.item
                saveOptions: {include_schedule: true}
            }

        return null

    canEditNodeColor: (row) ->
        target = @_getTargetNodeForColorChange(row)
        return false if !target?
        return @_canModifyType(target.type)

    _openNodeColorMenu: (row) ->
        return false if !row?.rowId?
        return false if !@canEditNodeColor(row)

        @activeColorMenuRowId = row.rowId
        target = @_getTargetNodeForColorChange(row)
        @nodeCustomColorByRowId[row.rowId] = @_normalizeColorValue(target?.item?.color)
        @_updateColorMenuPlacement(row.rowId)
        return true

    _getClosestGanttRowIdFromTarget: (target) ->
        node = target

        while node?
            if node.classList?.contains("gantt-tree-row")
                rowId = node.getAttribute?("data-gantt-row-id")
                return rowId if rowId?
            node = node.parentNode

        return null

    isColorMenuOpenUpward: (rowId) ->
        return !!@colorMenuOpenUpwardByRowId[rowId]

    _updateColorMenuPlacement: (rowId) ->
        return if !rowId?

        _.defer =>
            rowSelector = ".gantt-tree-row[data-gantt-row-id=\"#{rowId}\"]"
            rowElement = document.querySelector(rowSelector)
            iconElement = rowElement?.querySelector(".gantt-row-type-icon")
            dropdownElement = rowElement?.querySelector(".gantt-row-color-dropdown")
            leftPanel = document.querySelector(".gantt-left-panel")
            shouldOpenUpward = false

            if iconElement? and leftPanel?
                iconRect = iconElement.getBoundingClientRect()
                panelRect = leftPanel.getBoundingClientRect()
                dropdownHeight = dropdownElement?.getBoundingClientRect()?.height or 0
                dropdownHeight = 220 if dropdownHeight <= 0

                availableBelow = panelRect.bottom - iconRect.bottom
                availableAbove = iconRect.top - panelRect.top
                shouldOpenUpward = dropdownHeight + 8 > availableBelow and availableAbove > availableBelow

            return if !!@colorMenuOpenUpwardByRowId[rowId] == shouldOpenUpward

            @colorMenuOpenUpwardByRowId[rowId] = shouldOpenUpward
            @scope.$evalAsync()

    isNodeColorMenuOpen: (rowId) ->
        return @activeColorMenuRowId == rowId

    stopColorMenuEvent: (event) ->
        return if !event?
        isCustomColorInput = event.target?.classList?.contains("custom-color-input")
        event.preventDefault() if !isCustomColorInput
        event.stopPropagation()

    stopToolbarMenuEvent: (event) ->
        return if !event?
        event.stopPropagation()

    toggleZoomMenu: (event) ->
        @stopToolbarMenuEvent(event)
        @zoomMenuOpen = !@zoomMenuOpen
        @_syncTimelineWidthSliderValue() if @zoomMenuOpen

    isBarEditingLocked: ->
        return !!@barsLocked

    canToggleBarsLock: ->
        return true if @_canModifyType("epic")
        return true if @_canModifyType("story")
        return true if @_canModifyType("task")
        return false

    canUseColorPickerMode: ->
        return @canToggleBarsLock()

    canUseBarLinkMode: ->
        return false if @savingBarLinks
        return false if !@canToggleBarsLock()
        return (@ganttBars or []).length > 1

    _deactivateColorPickerMode: ->
        @colorPickerModeActive = false
        delete @colorMenuOpenUpwardByRowId[@activeColorMenuRowId] if @activeColorMenuRowId?
        @activeColorMenuRowId = null

    _deactivateBarLinkMode: ->
        @barLinkModeActive = false
        @pendingBarLinkSourceRowId = null

    toggleColorPickerMode: (event) ->
        @stopToolbarMenuEvent(event)
        return if !@canUseColorPickerMode()

        shouldActivate = !@colorPickerModeActive

        if !shouldActivate
            @_deactivateColorPickerMode()
            return

        @barsLocked = true
        @_deactivateBarLinkMode()
        @colorPickerModeActive = true

    toggleBarLinkMode: (event) ->
        @stopToolbarMenuEvent(event)
        return if !@canUseBarLinkMode()

        shouldActivate = !@barLinkModeActive

        if !shouldActivate
            @_deactivateBarLinkMode()
            return

        @barsLocked = true
        @_deactivateColorPickerMode()
        @barLinkModeActive = true
        @zoomMenuOpen = false

    isPendingBarLinkSource: (rowId) ->
        return @barLinkModeActive and @pendingBarLinkSourceRowId == rowId

    _hasBarLink: (sourceRowId, targetRowId) ->
        return _.some(@barLinks or [], (link) ->
            return link?.sourceRowId == sourceRowId and link?.targetRowId == targetRowId
        )

    _findBarLink: (sourceRowId, targetRowId) ->
        return _.find(@barLinks or [], (link) ->
            return link?.sourceRowId == sourceRowId and link?.targetRowId == targetRowId
        )

    _findScheduleDependencyForBarLink: (sourceRowId, targetRowId) ->
        sourceScheduleId = @_normalizeId(@scheduleIdByRowId[sourceRowId])
        targetScheduleId = @_normalizeId(@scheduleIdByRowId[targetRowId])
        return null if !sourceScheduleId? or !targetScheduleId?

        link = @_findBarLink(sourceRowId, targetRowId)
        dependencyId = @_normalizeId(link?.dependencyId)

        if dependencyId?
            dependencyById = _.find(@sourceScheduleDependencies or [], (dependency) =>
                return @_normalizeId(dependency?.id) == dependencyId
            )
            return dependencyById if dependencyById?

        return _.find(@sourceScheduleDependencies or [], (dependency) =>
            fromScheduleId = @_normalizeId(dependency?.from_schedule)
            toScheduleId = @_normalizeId(dependency?.to_schedule)
            return fromScheduleId == sourceScheduleId and toScheduleId == targetScheduleId
        )

    _createBarLinkDependency: (sourceRowId, targetRowId, options = {}) ->
        notify = options.notify != false
        sourceScheduleId = @_normalizeId(@scheduleIdByRowId[sourceRowId])
        targetScheduleId = @_normalizeId(@scheduleIdByRowId[targetRowId])

        if !sourceScheduleId? or !targetScheduleId?
            @confirm.notify("error") if notify
            return @q.reject()

        return @q.when() if @_hasBarLink(sourceRowId, targetRowId)

        @savingBarLinks = true

        return @repo.create("schedule-dependencies", {
            from_schedule: sourceScheduleId
            to_schedule: targetScheduleId
        }).then (dependency) =>
            @sourceScheduleDependencies.push(dependency)
            @_syncBarLinksFromDependencies()
            @scope.$evalAsync()
            @confirm.notify("success") if notify
            return dependency
        , (errorData) =>
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message) if notify
            return @q.reject(errorData)
        .finally =>
            @savingBarLinks = false

    _removeBarLinkDependency: (sourceRowId, targetRowId, options = {}) ->
        notify = options.notify != false
        dependency = @_findScheduleDependencyForBarLink(sourceRowId, targetRowId)

        if !dependency?
            @barLinks = _.filter(@barLinks or [], (link) ->
                return !(link?.sourceRowId == sourceRowId and link?.targetRowId == targetRowId)
            )
            @scope.$evalAsync()
            @confirm.notify("success") if notify
            return @q.when()

        @savingBarLinks = true
        dependencyId = @_normalizeId(dependency.id)

        return @repo.remove(dependency).then =>
            @sourceScheduleDependencies = _.filter(@sourceScheduleDependencies or [], (candidate) =>
                return @_normalizeId(candidate?.id) != dependencyId
            )
            @_syncBarLinksFromDependencies()
            @scope.$evalAsync()
            @confirm.notify("success") if notify
            return
        , (errorData) =>
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message) if notify
            return @q.reject(errorData)
        .finally =>
            @savingBarLinks = false

    _setBarLinkDependencyState: (sourceRowId, targetRowId, shouldBeLinked, options = {}) ->
        if shouldBeLinked
            return @q.when() if @_hasBarLink(sourceRowId, targetRowId)
            return @_createBarLinkDependency(sourceRowId, targetRowId, options)

        return @q.when() if !@_hasBarLink(sourceRowId, targetRowId)
        return @_removeBarLinkDependency(sourceRowId, targetRowId, options)

    _toggleBarLinkDependency: (sourceRowId, targetRowId, options = {}) ->
        skipHistory = !!options.skipHistory
        notify = options.notify != false
        previousLinked = @_hasBarLink(sourceRowId, targetRowId)
        nextLinked = !previousLinked
        historyEntry = @_buildBarLinkHistoryEntry(sourceRowId, targetRowId, previousLinked, nextLinked)

        return @_setBarLinkDependencyState(sourceRowId, targetRowId, nextLinked, {notify: notify}).then (result) =>
            @_registerBarChangeHistoryEntry(historyEntry) if !skipHistory
            return result

    toggleGanttBarLink: (sourceRowId, targetRowId) ->
        return false if !@barLinkModeActive
        return false if !sourceRowId? or !targetRowId?
        return false if sourceRowId == targetRowId
        return false if !@rowNodesById[sourceRowId]? or !@rowNodesById[targetRowId]?
        return false if @savingBarLinks

        @pendingBarLinkSourceRowId = null
        @_toggleBarLinkDependency(sourceRowId, targetRowId)
        return true

    registerGanttBarLinkClick: (rowId) ->
        return false if !@barLinkModeActive
        return false if !rowId?
        return false if !@rowNodesById[rowId]?
        return false if @savingBarLinks

        if !@pendingBarLinkSourceRowId?
            @pendingBarLinkSourceRowId = rowId
            return true

        sourceRowId = @pendingBarLinkSourceRowId
        @pendingBarLinkSourceRowId = null

        return true if sourceRowId == rowId

        @_toggleBarLinkDependency(sourceRowId, rowId)
        return true

    toggleBarsLock: (event) ->
        @stopToolbarMenuEvent(event)
        return if !@canToggleBarsLock()
        @barsLocked = !@barsLocked

        if !@barsLocked
            @_deactivateColorPickerMode()
            @_deactivateBarLinkMode()

    canUndoBarChange: ->
        return false if @barHistoryBusy
        return false if @treeRowReorderBusy
        return false if @savingBarLinks
        return @barChangeUndoStack.length > 0

    canRedoBarChange: ->
        return false if @barHistoryBusy
        return false if @treeRowReorderBusy
        return false if @savingBarLinks
        return @barChangeRedoStack.length > 0

    _pushBarChangeHistoryEntry: (stack, entry) ->
        return if !stack? or !entry?

        stack.push(angular.copy(entry))

        if @barChangeHistoryLimit > 0 and stack.length > @barChangeHistoryLimit
            stack.shift()

    _registerBarChangeHistoryEntry: (entry) ->
        return if !entry?
        @_pushBarChangeHistoryEntry(@barChangeUndoStack, entry)
        @barChangeRedoStack = []

    _buildBarChangeHistoryEntry: (rowId, startField, previousStart, previousDue, nextStart, nextDue) ->
        return {
            type: "dates"
            rowId: rowId
            startField: startField
            previous: {
                start: previousStart
                due: previousDue
            }
            next: {
                start: nextStart
                due: nextDue
            }
        }

    _buildColorChangeHistoryEntry: (targetRowId, previousColor, nextColor) ->
        return {
            type: "color"
            targetRowId: targetRowId
            previousColor: previousColor or null
            nextColor: nextColor or null
        }

    _buildRowReorderHistoryEntry: (rowId, previousIndex, nextIndex, parentRowId = null, rowType = null) ->
        return {
            type: "row-reorder"
            rowId: rowId
            rowType: rowType or null
            parentRowId: parentRowId
            previousIndex: previousIndex
            nextIndex: nextIndex
        }

    _buildBarLinkHistoryEntry: (sourceRowId, targetRowId, previousLinked, nextLinked) ->
        return {
            type: "link"
            sourceRowId: sourceRowId
            targetRowId: targetRowId
            previousLinked: !!previousLinked
            nextLinked: !!nextLinked
        }

    _applyColorChangeHistoryEntry: (entry, direction) ->
        return @q.reject() if !entry?

        targetRow = @rowNodesById[entry.targetRowId]
        return @q.reject() if !targetRow?

        targetColor = if direction == "undo" then entry.previousColor else entry.nextColor
        return @selectNodeColor(null, targetRow, targetColor, {
            skipHistory: true
            notify: false
            allowNull: true
        })

    _applyRowReorderHistoryEntry: (entry, direction) ->
        return @q.reject() if !entry?
        return @q.reject() if !entry.rowId?

        context = @getGanttRowReorderContext(entry.rowId)
        return @q.reject() if !context?
        return @q.reject() if entry.rowType? and context.rowType? and entry.rowType != context.rowType
        entryParentRowId = entry.parentRowId or null
        contextParentRowId = context.parentRowId or null
        return @q.reject() if entryParentRowId != contextParentRowId

        targetIndex = if direction == "undo" then entry.previousIndex else entry.nextIndex
        targetIndex = parseInt(targetIndex, 10)
        return @q.reject() if isNaN(targetIndex)

        maxIndex = Math.max(0, (context.siblingRowIds?.length or 1) - 1)
        targetIndex = Math.max(0, Math.min(maxIndex, targetIndex))

        currentIndex = parseInt(context.rowIndex, 10)
        return @q.when() if !isNaN(currentIndex) and currentIndex == targetIndex

        return @requestGanttRowReorder(entry.rowId, targetIndex, {
            skipHistory: true
            notify: false
        }).then (moved) =>
            return @q.reject() if moved == false
            return

    _applyBarLinkHistoryEntry: (entry, direction) ->
        return @q.reject() if !entry?
        return @q.reject() if !entry.sourceRowId? or !entry.targetRowId?

        shouldBeLinked = if direction == "undo" then !!entry.previousLinked else !!entry.nextLinked
        return @_setBarLinkDependencyState(entry.sourceRowId, entry.targetRowId, shouldBeLinked, {
            notify: false
        })

    _applyBarChangeHistoryEntry: (entry, direction) ->
        return @q.reject() if !entry?
        return @_applyColorChangeHistoryEntry(entry, direction) if entry.type == "color"
        return @_applyRowReorderHistoryEntry(entry, direction) if entry.type == "row-reorder"
        return @_applyBarLinkHistoryEntry(entry, direction) if entry.type == "link"

        targetState = if direction == "undo" then entry.previous else entry.next
        return @q.reject() if !targetState?

        return @saveBarDateValues(entry.rowId, targetState.start, targetState.due, {
            skipHistory: true
            notify: false
            startField: entry.startField
        })

    undoBarChange: (event) ->
        @stopToolbarMenuEvent(event)
        return @q.when() if @barHistoryBusy

        entry = @barChangeUndoStack.pop()
        return @q.when() if !entry?

        @barHistoryBusy = true
        return @_applyBarChangeHistoryEntry(entry, "undo").then =>
            @_pushBarChangeHistoryEntry(@barChangeRedoStack, entry)
            @confirm.notify("success")
            return
        , (errorData) =>
            @barChangeUndoStack.push(entry)
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message)
            return @q.reject(errorData)
        .finally =>
            @barHistoryBusy = false
            @scope.$evalAsync()

    redoBarChange: (event) ->
        @stopToolbarMenuEvent(event)
        return @q.when() if @barHistoryBusy

        entry = @barChangeRedoStack.pop()
        return @q.when() if !entry?

        @barHistoryBusy = true
        return @_applyBarChangeHistoryEntry(entry, "redo").then =>
            @_pushBarChangeHistoryEntry(@barChangeUndoStack, entry)
            @confirm.notify("success")
            return
        , (errorData) =>
            @barChangeRedoStack.push(entry)
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message)
            return @q.reject(errorData)
        .finally =>
            @barHistoryBusy = false
            @scope.$evalAsync()

    _getZoomCookieName: ->
        return buildGanttCookieName("layout_zoom", @scope)

    _getZoomSliderCookieName: ->
        return buildGanttCookieName("layout_zoom_slider", @scope)

    _persistZoomOption: ->
        cookieName = @_getZoomCookieName()
        writeGanttCookie(cookieName, @selectedZoomOption)

    _restoreZoomOptionFromCookie: ->
        cookieName = @_getZoomCookieName()
        option = readGanttCookie(cookieName)
        validOptions = ["daily", "weekly", "monthly"]
        return if validOptions.indexOf(option) == -1
        @selectedZoomOption = option

    _persistZoomSliderState: ->
        cookieName = @_getZoomSliderCookieName()
        weeklyBounds = @_getScaleWidthBounds("weekly")
        monthlyBounds = @_getScaleWidthBounds("monthly")

        zoomSliderState = {
            weekly: @_clampScaleWidthValue(@weekWidthRem, weeklyBounds)
            monthly: @_clampScaleWidthValue(@monthDayWidthRem, monthlyBounds)
        }

        writeGanttJsonCookie(cookieName, zoomSliderState)

    _restoreZoomSliderStateFromCookie: ->
        cookieName = @_getZoomSliderCookieName()
        zoomSliderState = readGanttJsonCookie(cookieName)
        return if !_.isObject(zoomSliderState)

        weeklyBounds = @_getScaleWidthBounds("weekly")
        monthlyBounds = @_getScaleWidthBounds("monthly")

        if zoomSliderState.weekly?
            parsedWeekly = parseFloat(zoomSliderState.weekly)
            if !isNaN(parsedWeekly)
                @weekWidthRem = @_clampScaleWidthValue(parsedWeekly, weeklyBounds)

        if zoomSliderState.monthly?
            parsedMonthly = parseFloat(zoomSliderState.monthly)
            if !isNaN(parsedMonthly)
                @monthDayWidthRem = @_clampScaleWidthValue(parsedMonthly, monthlyBounds)

    selectZoomOption: (option, event) ->
        @stopToolbarMenuEvent(event)
        return if !option?

        validOptions = ["daily", "weekly", "monthly"]
        return if validOptions.indexOf(option) == -1

        if @selectedZoomOption == option
            event?.preventDefault()
            @scope.$evalAsync()
            return

        @selectedZoomOption = option
        @_persistZoomOption()
        @_syncTimelineWidthSliderValue()

        @timelineStartAnchor = null
        @_refreshComputedData()
        @scope.$evalAsync()

    isTimelineWidthSliderDisabled: ->
        return @_getTimelineScale() == "daily"

    _getScaleWidthBounds: (scale = @_getTimelineScale()) ->
        if scale == "weekly"
            return {
                min: @weeklyColumnWidthRemMin
                max: @weeklyColumnWidthRemMax
            }

        if scale == "monthly"
            return {
                min: @monthlyDayWidthRemMin
                max: @monthlyDayWidthRemMax
            }

        return null

    _clampScaleWidthValue: (value, bounds) ->
        parsedValue = parseFloat(value)
        parsedValue = bounds.min if isNaN(parsedValue)
        parsedValue = Math.max(bounds.min, parsedValue)
        parsedValue = Math.min(bounds.max, parsedValue)
        return parsedValue

    _normalizeTimelineWidthSliderValue: (value) ->
        normalizedValue = parseFloat(value)
        normalizedValue = @timelineWidthSliderMin if isNaN(normalizedValue)
        normalizedValue = Math.max(@timelineWidthSliderMin, normalizedValue)
        normalizedValue = Math.min(@timelineWidthSliderMax, normalizedValue)
        return normalizedValue

    _getCurrentScaleWidthValue: (scale = @_getTimelineScale()) ->
        return @weekWidthRem if scale == "weekly"
        return @monthDayWidthRem if scale == "monthly"
        return null

    _setCurrentScaleWidthValue: (scale, value) ->
        if scale == "weekly"
            @weekWidthRem = value
            return

        if scale == "monthly"
            @monthDayWidthRem = value
            return

    _sliderValueToScaleWidth: (sliderValue, bounds) ->
        minSlider = @timelineWidthSliderMin
        maxSlider = @timelineWidthSliderMax
        sliderSpan = maxSlider - minSlider

        return bounds.min if sliderSpan <= 0

        normalizedSliderValue = @_normalizeTimelineWidthSliderValue(sliderValue)
        ratio = (normalizedSliderValue - minSlider) / sliderSpan
        return bounds.min + ((bounds.max - bounds.min) * ratio)

    _scaleWidthToSliderValue: (widthValue, bounds) ->
        widthSpan = bounds.max - bounds.min
        return @timelineWidthSliderMin if widthSpan <= 0

        clampedWidth = @_clampScaleWidthValue(widthValue, bounds)
        ratio = (clampedWidth - bounds.min) / widthSpan
        return @timelineWidthSliderMin + ((@timelineWidthSliderMax - @timelineWidthSliderMin) * ratio)

    _syncTimelineWidthSliderValue: ->
        scale = @_getTimelineScale()
        bounds = @_getScaleWidthBounds(scale)
        return if !bounds?

        widthValue = @_getCurrentScaleWidthValue(scale)
        sliderValue = @_scaleWidthToSliderValue(widthValue, bounds)
        @timelineWidthSliderValue = Math.round(sliderValue)

    onTimelineWidthSliderInput: (event) ->
        @stopToolbarMenuEvent(event)
        return if @isTimelineWidthSliderDisabled()

        scale = @_getTimelineScale()
        bounds = @_getScaleWidthBounds(scale)
        return if !bounds?

        sliderValue = @_normalizeTimelineWidthSliderValue(@timelineWidthSliderValue)
        @timelineWidthSliderValue = Math.round(sliderValue)

        nextWidthValue = @_sliderValueToScaleWidth(sliderValue, bounds)
        nextWidthValue = @_clampScaleWidthValue(nextWidthValue, bounds)
        currentWidthValue = @_getCurrentScaleWidthValue(scale)
        return if currentWidthValue? and Math.abs(nextWidthValue - currentWidthValue) < 0.0001

        @_setCurrentScaleWidthValue(scale, nextWidthValue)
        @_persistZoomSliderState()
        @_refreshTimelineLayoutForCurrentTree()
        @scope.$broadcast("tg:gantt-sync-rows-now")
        @scope.$evalAsync()

    _getTimelineScale: ->
        return "weekly" if @selectedZoomOption == "weekly"
        return "monthly" if @selectedZoomOption == "monthly"
        return "daily"

    _getColumnWidthRem: (scale = @_getTimelineScale()) ->
        if scale == "weekly"
            bounds = @_getScaleWidthBounds("weekly")
            return @_clampScaleWidthValue(@weekWidthRem, bounds)

        if scale == "monthly"
            bounds = @_getScaleWidthBounds("monthly")
            return @_clampScaleWidthValue(@monthDayWidthRem, bounds) * 30

        return @dayWidthRem

    _getTimelineSlotWidthRem: (scale = @_getTimelineScale()) ->
        columnWidthRem = @_getColumnWidthRem(scale)
        return (columnWidthRem / 7) if scale == "weekly"

        if scale == "monthly"
            bounds = @_getScaleWidthBounds("monthly")
            return @_clampScaleWidthValue(@monthDayWidthRem, bounds)

        return columnWidthRem

    _getWeeklyRangeLabel: (startMoment, endMoment) ->
        return "" if !startMoment? or !endMoment?
        return "#{startMoment.date()} - #{endMoment.date()}"

    _getMonthlyLabel: (startMoment) ->
        return "" if !startMoment?
        return startMoment.format("MMMM")

    _getTimelinePaddedStart: (startMoment, scale = @_getTimelineScale()) ->
        return moment().startOf("day") if !startMoment?

        if scale == "weekly"
            return startMoment.clone().startOf("isoWeek").subtract(1, "week")

        if scale == "monthly"
            return startMoment.clone().startOf("month").subtract(1, "month")

        return startMoment.clone().subtract(3, "day").startOf("day")

    _getTimelinePaddedEnd: (endMoment, scale = @_getTimelineScale()) ->
        return moment().startOf("day") if !endMoment?

        if scale == "weekly"
            return endMoment.clone().endOf("isoWeek").add(1, "week")

        if scale == "monthly"
            return endMoment.clone().endOf("month").add(1, "month").endOf("month")

        return endMoment.clone().add(3, "day").startOf("day")

    _hasAncestorWithClass: (target, className) ->
        node = target

        while node?
            return true if node.classList?.contains(className)
            node = node.parentNode

        return false

    onDocumentClick: (event) ->
        shouldRefreshScope = false

        target = event?.target
        handledColorPickerRowClick = false
        clickedRowId = @_getClosestGanttRowIdFromTarget(target)

        if @colorPickerModeActive and clickedRowId?
            clickedRow = @rowNodesById[clickedRowId]
            handledColorPickerRowClick = @_openNodeColorMenu(clickedRow)
            if handledColorPickerRowClick
                event?.preventDefault()
                shouldRefreshScope = true

        if @activeColorMenuRowId?
            if !@_hasAncestorWithClass(target, "gantt-row-type-icon") and !handledColorPickerRowClick
                delete @colorMenuOpenUpwardByRowId[@activeColorMenuRowId] if @activeColorMenuRowId?
                @activeColorMenuRowId = null
                shouldRefreshScope = true

        if @zoomMenuOpen
            if !@_hasAncestorWithClass(target, "gantt-toolbar-zoom")
                @zoomMenuOpen = false
                shouldRefreshScope = true

        @scope.$evalAsync() if shouldRefreshScope

    toggleNodeColorMenu: (event, row) ->
        @stopColorMenuEvent(event)
        return if !row?.rowId?
        return if !@colorPickerModeActive

        if @activeColorMenuRowId == row?.rowId
            delete @colorMenuOpenUpwardByRowId[row.rowId]
            @activeColorMenuRowId = null
            return

        @_openNodeColorMenu(row)

    onNodeColorInputKeyDown: (event, row) ->
        return if !event?
        return if event.which != 13

        @stopColorMenuEvent(event)
        return @applyNodeCustomColor(row)

    onNodeColorInputBlur: (row) ->
        return @applyNodeCustomColor(row)

    applyNodeCustomColor: (row) ->
        return @q.when() if !row?

        target = @_getTargetNodeForColorChange(row)
        currentColor = @_normalizeColorValue(target?.item?.color)
        typedColor = @_normalizeColorValue(@nodeCustomColorByRowId[row.rowId])

        return @q.when() if !typedColor? or typedColor == currentColor
        return @selectNodeColor(null, row, typedColor)

    selectNodeColor: (event, row, color, options = {}) ->
        @stopColorMenuEvent(event)
        return @q.when() if !row?
        return @q.reject() if @barHistoryBusy and !options.skipHistory

        hasColorValue = color? and "#{color}".trim().length > 0
        normalizedColor = if hasColorValue then @_normalizeColorValue(color) else null

        return @q.when() if hasColorValue and !normalizedColor?
        return @q.when() if !normalizedColor? and !options.allowNull

        target = @_getTargetNodeForColorChange(row)
        return @q.reject() if !target?
        return @q.reject() if !@_canModifyType(target.type)

        currentColor = @_normalizeColorValue(target.item?.color)
        return @q.when() if currentColor == normalizedColor

        historyEntry = null
        if !options.skipHistory and target.row?.rowId?
            historyEntry = @_buildColorChangeHistoryEntry(
                target.row?.rowId
                currentColor
                normalizedColor
            )

        target.item.setAttr("color", normalizedColor)

        affectedRows = _.uniq([row.rowId, target.row.rowId])
        _.each(affectedRows, (affectedRowId) =>
            @savingRows[affectedRowId] = true
        )

        saveOptions = target.saveOptions or {}
        return @repo.save(target.item, true, saveOptions).then =>
            _.each(affectedRows, (affectedRowId) =>
                delete @savingRows[affectedRowId]
            )

            @_registerBarChangeHistoryEntry(historyEntry) if historyEntry?
            @activeColorMenuRowId = null
            delete @colorMenuOpenUpwardByRowId[row?.rowId] if row?.rowId?
            @timelineStartAnchor = null
            @buildGanttData(@sourceEpics, @sourceUserstories, @sourceTasks)
            @scope.$evalAsync()
            @confirm.notify("success") if options.notify != false
            return
        , (errorData) =>
            target.item.revert()
            _.each(affectedRows, (affectedRowId) =>
                delete @savingRows[affectedRowId]
            )
            @confirm.notify("error") if options.notify != false
            return @q.reject(errorData)

    saveBarDateRange: (rowId, startDay, endDay, options = {}) ->
        row = @rowNodesById[rowId]
        return @q.reject() if !row?.item? or !row.canEdit

        normalizedStartDay = Math.max(1, parseInt(startDay, 10) or 1)
        normalizedEndDay = Math.max(normalizedStartDay, parseInt(endDay, 10) or normalizedStartDay)

        startMoment = @_getTimelineMomentBySlotIndex(normalizedStartDay)
        dueMoment = @_getTimelineMomentBySlotIndex(normalizedEndDay)
        return @q.reject() if !startMoment? or !dueMoment?

        nextStartValue = startMoment.format("YYYY-MM-DD")
        nextDueValue = dueMoment.format("YYYY-MM-DD")
        return @saveBarDateValues(rowId, nextStartValue, nextDueValue, options)

    saveBarDateValues: (rowId, startValue, dueValue, options = {}) ->
        row = @rowNodesById[rowId]
        return @q.reject() if !row?.item? or !row.canEdit
        return @q.reject() if @barHistoryBusy and !options.skipHistory

        startField = options.startField or @_getStartEditableField(row.item)
        nextStartValue = @_normalizeDateForInput(startValue)
        nextDueValue = @_normalizeDateForInput(dueValue)
        currentStartValue = @_normalizeDateForInput(row.item[startField])
        currentDueValue = @_normalizeDateForInput(row.item.due_date)

        return @q.when() if currentStartValue == nextStartValue and currentDueValue == nextDueValue

        historyEntry = null
        if !options.skipHistory
            historyEntry = @_buildBarChangeHistoryEntry(
                rowId
                startField
                currentStartValue
                currentDueValue
                nextStartValue
                nextDueValue
            )

        affectedEntities = @_collectAffectedEntitiesForDateSave(row)

        row.item.setAttr(startField, nextStartValue)
        row.item.setAttr("due_date", nextDueValue)
        @savingRows[rowId] = true

        return @repo.save(row.item, true, {include_schedule: true}).then =>
            delete @savingRows[rowId]
            return @_reloadGanttDataSilently().then =>
                @_registerBarChangeHistoryEntry(historyEntry) if historyEntry?
                @confirm.notify("success") if options.notify != false
                return
            , =>
                return @_reloadDateAffectedEntities(affectedEntities).then =>
                    @_registerBarChangeHistoryEntry(historyEntry) if historyEntry?
                    @confirm.notify("success") if options.notify != false
                    return
                , =>
                    @_registerBarChangeHistoryEntry(historyEntry) if historyEntry?
                    @timelineStartAnchor = null
                    @buildGanttData(@sourceEpics, @sourceUserstories, @sourceTasks)
                    @scope.$evalAsync()
                    @confirm.notify("success") if options.notify != false
                    return
        , (errorData) =>
            row.item.revert()
            delete @savingRows[rowId]
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message) if options.notify != false
            return @q.reject(errorData)

    canCreateBarDateRange: (rowId) ->
        row = @rowNodesById[rowId]
        return false if !row?.item? or !row.canEdit
        return false if @savingRows[rowId]
        return false if row.startMoment? or row.dueMoment?
        return true

    getGanttRowResizeLimits: (rowId) ->
        row = @rowNodesById[rowId]
        return null if !row?
        return @_buildResizeLimits(row, @timeline)

    _collectAffectedEntitiesForDateSave: (row) ->
        affected = {
            taskId: null
            storyId: null
            epicId: null
        }

        return affected if !row?.item?

        rowItemId = @_normalizeId(row.item.id)
        rowType = row.type

        if rowType == "epic"
            affected.epicId = rowItemId
            return affected

        if rowType == "story"
            affected.storyId = rowItemId
            affected.epicId = @_normalizeId(row.epicId)
            return affected

        if rowType == "task"
            affected.taskId = rowItemId
            affected.storyId = @_normalizeId(@_extractStoryId(row.item))
            affected.epicId = @_normalizeId(row.epicId)

            if !affected.epicId? and affected.storyId?
                storyRow = @rowNodesById["story-#{affected.storyId}"]
                affected.epicId = @_normalizeId(storyRow?.epicId)

        return affected

    _upsertSourceEntity: (entityName, entityModel) ->
        return if !entityModel?.id?

        source = null
        if entityName == "epics"
            source = @sourceEpics
        else if entityName == "userstories"
            source = @sourceUserstories
        else if entityName == "tasks"
            source = @sourceTasks

        return if !source?

        normalizedEntityId = @_normalizeId(entityModel.id)
        updated = false

        for index in [0...source.length]
            sourceItem = source[index]
            continue if @_normalizeId(sourceItem?.id) != normalizedEntityId
            source[index] = entityModel
            updated = true
            break

        source.push(entityModel) if !updated

    _reloadDateAffectedEntities: (affectedEntities) ->
        requests = []

        addRequest = (entityName, entityId) =>
            normalizedId = @_normalizeId(entityId)
            return if !normalizedId?

            request = @repo.queryOne(entityName, normalizedId, {include_schedule: true}).then (entityModel) =>
                @_upsertSourceEntity(entityName, entityModel)
                return entityModel
            , =>
                return null

            requests.push(request)

        addRequest("tasks", affectedEntities?.taskId)
        addRequest("userstories", affectedEntities?.storyId)
        addRequest("epics", affectedEntities?.epicId)

        reloadPromise = if requests.length then @q.all(requests) else @q.when([])

        return reloadPromise.then =>
            @timelineStartAnchor = null
            @buildGanttData(@sourceEpics, @sourceUserstories, @sourceTasks)
            @scope.$evalAsync()
            return

    _extractApiErrorMessage: (errorData) ->
        payload = errorData?.data or errorData
        return null if !payload?

        if _.isString(payload._error_message) and payload._error_message.length
            return payload._error_message

        if _.isArray(payload.__all__) and payload.__all__.length
            return payload.__all__[0]

        for own key, value of payload
            continue if key == "_error_message" or key == "__all__"

            if _.isArray(value) and value.length
                return value[0]

            if _.isString(value) and value.length
                return value

        return null

    _buildTree: (epics, userstories, tasks) ->
        epicNodes = _.map(@_sortBySchedulePositionWithIdFallback(epics), (epic) => @_buildNode("epic", epic))
        epicNodesById = {}
        rootStoryNodes = []
        rootTaskNodes = []

        _.each(epicNodes, (epicNode) =>
            epicNodesById["#{epicNode.item.id}"] = epicNode
            epicNode.epicId = @_normalizeId(epicNode.item?.id)
            epicNode.barColor = @_extractEpicColor(epicNode.item)
        )

        storyNodesById = {}

        _.each(@_sortBySchedulePositionWithIdFallback(userstories), (story) =>
            storyNode = @_buildNode("story", story)
            storyNodesById["#{story.id}"] = storyNode

            epicId = @_extractEpicId(story, epicNodesById)
            parentEpic = epicNodesById["#{epicId}"]

            if parentEpic?
                storyNode.epicId = @_normalizeId(parentEpic.item?.id)
                storyNode.barColor = parentEpic.barColor or @_extractStoryEpicColor(story, epicNodesById)
                parentEpic.children.push(storyNode)
            else
                storyNode.epicId = null
                storyNode.barColor = @_extractOwnItemColor(story) or @_getNoEpicBarColor()
                rootStoryNodes.push(storyNode)
        )

        _.each(@_sortBySchedulePositionWithIdFallback(tasks), (task) =>
            taskNode = @_buildNode("task", task)
            storyId = @_extractStoryId(task)
            parentStory = storyNodesById["#{storyId}"]

            if parentStory?
                taskNode.epicId = parentStory.epicId
                if taskNode.epicId?
                    taskNode.barColor = parentStory.barColor or @_getNoEpicBarColor()
                else
                    taskNode.barColor = parentStory.barColor or @_extractOwnItemColor(task) or @_getNoEpicBarColor()
                parentStory.children.push(taskNode)
            else
                taskNode.epicId = null
                taskNode.barColor = @_extractOwnItemColor(task) or @_getNoEpicBarColor()
                rootTaskNodes.push(taskNode)
        )

        tree = epicNodes.concat(rootStoryNodes).concat(rootTaskNodes)
        return tree

    _buildNode: (type, item) ->
        rowPrefix = if type == "story" then "story" else type
        rowId = "#{rowPrefix}-#{item.id}"
        inputId = "gantt-node-#{rowId}"
        label = "#{@_typeLabel(type)}: #{@_itemTitle(item)}"
        startMoment = @_extractStartMoment(item)
        dueMoment = @_extractDueMoment(item, startMoment)
        progressValue = @_defaultProgressFromItem(item)

        return {
            type: type
            item: item
            rowId: rowId
            inputId: inputId
            label: label
            assigneeLabel: @_getAssignedToName(item)
            ehLabel: @_formatHoursLabel(item)
            startMoment: startMoment
            dueMoment: dueMoment
            startLabel: @_formatDateShort(startMoment)
            dueLabel: @_formatDateShort(dueMoment)
            progressValue: progressValue
            progressLabel: "#{progressValue}%"
            canEdit: @_canModifyType(type)
            barColor: null
            epicId: null
            children: []
            isPlaceholder: false
        }

    _normalizeId: (value) ->
        return null if !value?

        if _.isObject(value)
            return @_normalizeId(value.id) if value.id?
            return null

        numericId = parseInt(value, 10)
        return numericId if !isNaN(numericId)
        return "#{value}"

    _extractEpicIdFromList: (story, epicNodesById = {}) ->
        return null if !story?

        epics = story.epics
        return null if !_.isArray(epics) or !epics.length

        projectId = @_normalizeId(@scope.projectId)
        fallbackEpicId = null

        for epic in epics
            epicId = @_normalizeId(epic)
            continue if !epicId?

            fallbackEpicId = epicId if !fallbackEpicId?

            if _.isObject(epic) and epic.project?.id? and projectId?
                epicProjectId = @_normalizeId(epic.project.id)
                continue if epicProjectId? and epicProjectId != projectId

            return epicId if epicNodesById["#{epicId}"]?
        return fallbackEpicId

    _extractEpicId: (story, epicNodesById = {}) ->
        return null if !story?

        epicIdFromList = @_extractEpicIdFromList(story, epicNodesById)
        return epicIdFromList if epicIdFromList?

        if _.isObject(story.epic)
            return @_normalizeId(story.epic.id) if story.epic?.id?

        if story.epic?
            normalizedEpicId = @_normalizeId(story.epic)
            return normalizedEpicId if normalizedEpicId?

        if story.epic_extra_info?.id?
            normalizedEpicInfoId = @_normalizeId(story.epic_extra_info.id)
            return normalizedEpicInfoId if normalizedEpicInfoId?

        return null

    _normalizeColorValue: (colorValue) ->
        return null if !colorValue?

        rawColor = "#{colorValue}".trim()
        return null if !rawColor.length

        return rawColor if /^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(rawColor)
        return "##{rawColor}" if /^[0-9a-f]{3}([0-9a-f]{3})?$/i.test(rawColor)
        return rawColor if /^(rgb|hsl)a?\(/i.test(rawColor)
        return rawColor if /^[a-z]+$/i.test(rawColor)

        return null

    _extractEpicColor: (epic) ->
        return null if !epic?
        return @_normalizeColorValue(epic.color)

    _extractStoryEpicColor: (story, epicNodesById = {}) ->
        return null if !story?

        epicId = @_extractEpicId(story, epicNodesById)
        if epicId?
            mappedEpic = epicNodesById["#{epicId}"]
            mappedEpicColor = @_extractEpicColor(mappedEpic?.item)
            return mappedEpicColor if mappedEpicColor?

        directEpicColor = @_normalizeColorValue(story.epic?.color)
        return directEpicColor if directEpicColor?

        epicInfoColor = @_normalizeColorValue(story.epic_extra_info?.color)
        return epicInfoColor if epicInfoColor?

        if _.isArray(story.epics)
            for epic in story.epics
                color = @_normalizeColorValue(epic?.color)
                return color if color?

        return null

    _extractOwnItemColor: (item) ->
        return null if !item?
        return @_normalizeColorValue(item.color)

    _getNoEpicBarColor: ->
        return "rgb(112, 114, 143)"

    _extractStoryId: (task) ->
        return null if !task?

        if _.isObject(task.user_story)
            return task.user_story.id if task.user_story?.id?

        return task.user_story if task.user_story?
        return task.user_story_extra_info.id if task.user_story_extra_info?.id?
        return null

    _sortBySchedulePositionWithIdFallback: (items = []) ->
        itemsById = @_sortById(items)
        return _.sortBy(itemsById, (item) ->
            rawPosition = item?.schedule_position

            if _.isNumber(rawPosition) and isFinite(rawPosition) and rawPosition > 0
                return rawPosition

            numericPosition = parseInt(rawPosition, 10)
            return numericPosition if !isNaN(numericPosition) and numericPosition > 0

            return 9007199254740991
        )

    _sortById: (items = []) ->
        return _.sortBy(items or [], (item) ->
            rawId = item?.id
            if _.isNumber(rawId)
                return rawId

            numericId = parseInt(rawId, 10)
            return numericId if !isNaN(numericId)

            return rawId or 0
        )

    _typeLabel: (type) ->
        return "Epic" if type == "epic"
        return "Story" if type == "story"
        return "Task" if type == "task"
        return "Item"

    _itemTitle: (item) ->
        return item?.subject or item?.name or "-"

    _parseDate: (value) ->
        return null if !value?

        parsed = moment(value)
        return null if !parsed.isValid()

        return parsed.startOf("day")

    _extractStartMoment: (item) ->
        return null if !item?

        fields = ["actual_start", "estimated_start"]

        for field in fields
            parsed = @_parseDate(item[field])
            return parsed if parsed?

        return null

    _extractDueMoment: (item, startMoment) ->
        return null if !item?

        fields = ["due_date"]

        for field in fields
            parsed = @_parseDate(item?[field])
            continue if !parsed?

            if startMoment? and parsed.isBefore(startMoment)
                return startMoment.clone()

            return parsed

        return null

    _formatDateShort: (dateMoment) ->
        return "-" if !dateMoment?
        return dateMoment.format("DD MMM")

    _getAssignedToName: (item) ->
        return "-" if !item?

        member = item.assigned_to_extra_info

        if !member? and item.assigned_to?
            member = @membersById["#{item.assigned_to}"]

        return "-" if !member?
        return member.full_name_display or member.full_name or member.username or "-"

    _extractHoursValue: (item) ->
        return null if !item?

        candidates = [
            item.estimated_hours
            item.total_hours
            item.total_estimated_hours
            item.hours
        ]

        for value in candidates
            continue if !value?

            if _.isNumber(value)
                return value

            raw = "#{value}".replace(",", ".").replace(/[^0-9.-]/g, "")
            parsed = parseFloat(raw)
            return parsed if !isNaN(parsed)

        return null

    _formatHoursLabel: (item) ->
        hours = @_extractHoursValue(item)
        return "-" if !hours?

        normalizedHours = if Math.round(hours) == hours then Math.round(hours) else Math.round(hours * 10) / 10
        return "#{normalizedHours}h"

    _isClosed: (item) ->
        return false if !item?
        return true if item.is_closed
        return true if item.status_extra_info?.is_closed
        return true if item.status?.is_closed
        return false

    _defaultProgressFromItem: (item) ->
        return null if !item?

        rawProgress = item.progress

        if _.isNumber(rawProgress)
            return @_clampProgress(rawProgress)

        if _.isString(rawProgress)
            parsedProgress = parseFloat(rawProgress.replace(",", "."))
            return @_clampProgress(parsedProgress) if !isNaN(parsedProgress)

        return 100 if @_isClosed(item)
        return 0

    _clampProgress: (value) ->
        parsedValue = parseFloat(value)
        parsedValue = 0 if isNaN(parsedValue)
        parsedValue = Math.max(0, parsedValue)
        parsedValue = Math.min(100, parsedValue)
        return Math.round(parsedValue)

    _computeNodeProgress: (node) ->
        progress = null

        if node.type == "task"
            progress = @_defaultProgressFromItem(node.item)
        else
            childProgress = []

            _.each(node.children or [], (child) =>
                childValue = @_computeNodeProgress(child)
                childProgress.push(childValue) if _.isNumber(childValue)
            )

            if childProgress.length
                total = _.reduce(childProgress, ((sum, value) -> sum + value), 0)
                progress = Math.round(total / childProgress.length)
            else
                progress = @_defaultProgressFromItem(node.item)

        if _.isNumber(progress)
            node.progressValue = @_clampProgress(progress)
            node.progressLabel = "#{node.progressValue}%"
        else
            node.progressValue = null
            node.progressLabel = "-"

        return node.progressValue

    _flattenRows: (tree) ->
        rows = []
        walk = (node) ->
            rows.push(node)
            _.each(node.children or [], (child) ->
                walk(child)
            )

        _.each(tree or [], (node) ->
            walk(node)
        )

        return rows

    _formatRemValue: (value) ->
        parsed = parseFloat(value)
        parsed = 0 if isNaN(parsed)
        return "#{Math.round(parsed * 10000) / 10000}"

    _getTimelineColumnSlotCount: (column) ->
        slotCount = parseInt(column?.slotCount, 10)
        if !isNaN(slotCount) and slotCount > 0
            return slotCount

        if column?.startMoment? and column?.endMoment?
            slotCount = column.endMoment.diff(column.startMoment, "days") + 1
            return Math.max(1, slotCount)

        return 1

    _getTimelineColumnWidthRem: (column, fallbackColumnWidthRem) ->
        widthRem = parseFloat(column?.widthRem)
        if !isNaN(widthRem) and widthRem > 0
            return widthRem

        fallbackWidthRem = parseFloat(fallbackColumnWidthRem)
        if !isNaN(fallbackWidthRem) and fallbackWidthRem > 0
            return fallbackWidthRem

        return @dayWidthRem

    _getTimelineTotalSlots: (columns) ->
        totalSlots = 0

        _.each(columns or [], (column) =>
            totalSlots += @_getTimelineColumnSlotCount(column)
        )

        return Math.max(totalSlots, 1)

    _getTimelineWidthRem: (columns, fallbackColumnWidthRem) ->
        widthRem = 0

        _.each(columns or [], (column) =>
            widthRem += @_getTimelineColumnWidthRem(column, fallbackColumnWidthRem)
        )

        return Math.max(widthRem, @_getTimelineColumnWidthRem(null, fallbackColumnWidthRem))

    _buildTimelineColumnsStyle: (columns, timelineWidthRem, fallbackColumnWidthRem) ->
        columnWidths = _.map(columns or [], (column) =>
            return @_formatRemValue(@_getTimelineColumnWidthRem(column, fallbackColumnWidthRem))
        )

        if !columnWidths.length
            fallbackWidthRem = @_formatRemValue(@_getTimelineColumnWidthRem(null, fallbackColumnWidthRem))
            return {
                "grid-template-columns": "repeat(1, #{fallbackWidthRem}rem)"
                width: "#{fallbackWidthRem}rem"
            }

        hasUniformWidth = _.every(columnWidths, (width) ->
            return width == columnWidths[0]
        )

        templateColumns = if hasUniformWidth
            "repeat(#{columnWidths.length}, #{columnWidths[0]}rem)"
        else
            _.map(columnWidths, (width) -> "#{width}rem").join(" ")

        return {
            "grid-template-columns": templateColumns
            width: "#{@_formatRemValue(timelineWidthRem)}rem"
        }

    _buildTimelineMonths: (columns, fallbackColumnWidthRem) ->
        months = []
        currentMonth = null

        _.each(columns or [], (column) =>
            monthKey = column.monthKey or column.startMoment?.format("YYYY-MM")
            monthLabel = column.monthLabel or column.startMoment?.format("MMM YYYY") or "-"
            columnWidthRem = @_getTimelineColumnWidthRem(column, fallbackColumnWidthRem)
            columnSlotCount = @_getTimelineColumnSlotCount(column)

            if !currentMonth? or currentMonth.key != monthKey
                currentMonth = {
                    key: monthKey or "month-#{months.length}"
                    label: monthLabel
                    days: columnSlotCount
                    widthRem: columnWidthRem
                }
                months.push(currentMonth)
                return

            currentMonth.days += columnSlotCount
            currentMonth.widthRem += columnWidthRem
        )

        return months

    _findTimelineSlotIndexForMoment: (targetMoment, timeline = @timeline) ->
        totalSlots = parseInt(timeline?.totalDays, 10) or 1
        totalSlots = Math.max(totalSlots, 1)
        timelineStart = timeline?.start

        return 1 if !timelineStart?
        return 1 if !targetMoment?

        normalizedMoment = targetMoment.clone().startOf("day")
        slotIndex = normalizedMoment.diff(timelineStart, "days") + 1
        slotIndex = Math.max(1, Math.min(totalSlots, slotIndex))
        return slotIndex

    _getTimelineMomentBySlotIndex: (slotIndex) ->
        totalSlots = parseInt(@timeline?.totalDays, 10) or 1
        totalSlots = Math.max(totalSlots, 1)
        timelineStart = @timeline?.start
        return null if !timelineStart?

        normalizedIndex = parseInt(slotIndex, 10)
        normalizedIndex = 1 if isNaN(normalizedIndex)
        normalizedIndex = Math.max(1, Math.min(totalSlots, normalizedIndex))

        return timelineStart.clone().add(normalizedIndex - 1, "day").startOf("day")

    _emptyTimeline: ->
        scale = @_getTimelineScale()
        now = moment().startOf("day")
        widthRem = @_getColumnWidthRem(scale)
        slotWidthRem = @_getTimelineSlotWidthRem(scale)
        columnStart = now.clone()
        columnEnd = now.clone()
        dayLabel = now.date()
        dayKey = now.format("YYYY-MM-DD")
        slotCount = 1
        columnWidthRem = widthRem
        bandKey = columnStart.format("YYYY-MM")
        bandLabel = columnStart.format("MMM YYYY")

        if scale == "weekly"
            columnStart = now.clone().startOf("isoWeek")
            columnEnd = columnStart.clone().add(6, "day")
            dayLabel = @_getWeeklyRangeLabel(columnStart, columnEnd)
            dayKey = columnStart.format("GGGG-[W]WW")
            slotCount = 7
            bandKey = columnStart.format("YYYY-MM")
            bandLabel = columnStart.format("MMM YYYY")
        else if scale == "monthly"
            columnStart = now.clone().startOf("month")
            columnEnd = now.clone().endOf("month")
            dayLabel = @_getMonthlyLabel(columnStart)
            dayKey = columnStart.format("YYYY-MM")
            slotCount = columnEnd.diff(columnStart, "days") + 1
            columnWidthRem = slotCount * slotWidthRem
            bandKey = columnStart.format("YYYY")
            bandLabel = columnStart.format("YYYY")

        columns = [{
            key: dayKey
            label: dayLabel
            isToday: true
            startMoment: columnStart
            endMoment: columnEnd
            monthKey: bandKey
            monthLabel: bandLabel
            slotCount: slotCount
            widthRem: columnWidthRem
        }]
        months = @_buildTimelineMonths(columns, widthRem)
        totalSlots = @_getTimelineTotalSlots(columns)
        timelineWidthRem = @_getTimelineWidthRem(columns, widthRem)

        return {
            start: columnStart.clone()
            end: columnEnd.clone()
            months: months
            days: [{
                key: dayKey
                label: dayLabel
                isToday: true
            }]
            columns: columns
            scale: scale
            columnWidthRem: widthRem
            slotWidthRem: slotWidthRem
            totalDays: totalSlots
            rowCount: 1
            timelineWidthRem: timelineWidthRem
            todayLineStyle: @_buildTodayLineStyle(columns, widthRem)
            dayColumnsStyle: @_buildTimelineColumnsStyle(columns, timelineWidthRem, widthRem)
            gridStyle: {
                width: "#{@_formatRemValue(timelineWidthRem)}rem"
            }
            svgStyle: {width: "#{@_formatRemValue(timelineWidthRem)}rem", height: "100%"}
        }

    _buildTodayLineStyle: (columns, fallbackColumnWidthRem) ->
        return null if !columns?.length

        today = moment().startOf("day")
        leftRem = 0

        for column, index in columns
            columnStart = column.startMoment
            columnEnd = column.endMoment or column.startMoment
            columnWidthRem = @_getTimelineColumnWidthRem(column, fallbackColumnWidthRem)
            continue if !columnStart? or !columnEnd?

            isInsideColumn = !today.isBefore(columnStart, "day") and !today.isAfter(columnEnd, "day")
            if isInsideColumn
                return {
                    left: "#{@_formatRemValue(leftRem)}rem"
                    width: "#{@_formatRemValue(columnWidthRem)}rem"
                }

            leftRem += columnWidthRem

        return null

    _buildTimeline: (rows) ->
        allDates = []
        today = moment().startOf("day")
        scale = @_getTimelineScale()
        columnWidthRem = @_getColumnWidthRem(scale)
        slotWidthRem = @_getTimelineSlotWidthRem(scale)

        _.each(rows or [], (row) ->
            return if row.isPlaceholder
            allDates.push(row.startMoment.clone()) if row.startMoment?
            allDates.push(row.dueMoment.clone()) if row.dueMoment?
        )

        if !allDates.length
            return @_emptyTimeline()

        start = allDates[0].clone()
        end = allDates[0].clone()

        _.each(allDates, (date) ->
            start = date.clone() if date.isBefore(start)
            end = date.clone() if date.isAfter(end)
        )

        computedStart = @_getTimelinePaddedStart(start, scale)

        if !@timelineStartAnchor?
            @timelineStartAnchor = computedStart.clone()

        start = @timelineStartAnchor.clone()
        end = @_getTimelinePaddedEnd(end, scale)

        columns = []

        if scale == "weekly"
            weekCursor = start.clone().startOf("day")

            while weekCursor.isSameOrBefore(end, "day")
                weekStart = weekCursor.clone()
                weekEnd = weekStart.clone().add(6, "day")
                weekEnd = end.clone() if weekEnd.isAfter(end, "day")

                columns.push({
                    key: weekStart.format("GGGG-[W]WW")
                    label: @_getWeeklyRangeLabel(weekStart, weekEnd)
                    isToday: !today.isBefore(weekStart, "day") and !today.isAfter(weekEnd, "day")
                    startMoment: weekStart
                    endMoment: weekEnd
                    monthKey: weekStart.format("YYYY-MM")
                    monthLabel: weekStart.format("MMM YYYY")
                    slotCount: 7
                    widthRem: columnWidthRem
                })

                weekCursor = weekStart.clone().add(7, "day")
        else if scale == "monthly"
            monthCursor = start.clone().startOf("month")

            while monthCursor.isSameOrBefore(end, "month")
                monthStart = monthCursor.clone().startOf("month")
                monthEnd = monthCursor.clone().endOf("month")
                visibleStart = if monthStart.isBefore(start, "day") then start.clone() else monthStart
                visibleEnd = if monthEnd.isAfter(end, "day") then end.clone() else monthEnd
                slotCount = visibleEnd.diff(visibleStart, "days") + 1
                slotCount = Math.max(1, slotCount)

                columns.push({
                    key: monthCursor.format("YYYY-MM")
                    label: @_getMonthlyLabel(monthCursor)
                    isToday: !today.isBefore(visibleStart, "day") and !today.isAfter(visibleEnd, "day")
                    startMoment: visibleStart
                    endMoment: visibleEnd
                    monthKey: monthCursor.format("YYYY")
                    monthLabel: monthCursor.format("YYYY")
                    slotCount: slotCount
                    widthRem: slotCount * slotWidthRem
                })

                monthCursor.add(1, "month")
        else
            dayCursor = start.clone()

            while dayCursor.isSameOrBefore(end, "day")
                dayMoment = dayCursor.clone()
                columns.push({
                    key: dayMoment.format("YYYY-MM-DD")
                    label: dayMoment.date()
                    isToday: dayMoment.isSame(today, "day")
                    startMoment: dayMoment
                    endMoment: dayMoment.clone()
                    monthKey: dayMoment.format("YYYY-MM")
                    monthLabel: dayMoment.format("MMM YYYY")
                    slotCount: 1
                    widthRem: columnWidthRem
                })

                dayCursor.add(1, "day")

        months = @_buildTimelineMonths(columns, columnWidthRem)
        days = _.map(columns, (column) ->
            return {
                key: column.key
                label: column.label
                isToday: column.isToday
            }
        )

        totalDays = @_getTimelineTotalSlots(columns)
        rowCount = Math.max((rows or []).length, 1)
        timelineWidthRem = @_getTimelineWidthRem(columns, columnWidthRem)

        return {
            start: start
            end: end
            months: months
            days: days
            columns: columns
            scale: scale
            columnWidthRem: columnWidthRem
            slotWidthRem: slotWidthRem
            totalDays: totalDays
            rowCount: rowCount
            timelineWidthRem: timelineWidthRem
            todayLineStyle: @_buildTodayLineStyle(columns, columnWidthRem)
            dayColumnsStyle: @_buildTimelineColumnsStyle(columns, timelineWidthRem, columnWidthRem)
            gridStyle: {
                width: "#{@_formatRemValue(timelineWidthRem)}rem"
            }
            svgStyle: {width: "#{@_formatRemValue(timelineWidthRem)}rem", height: "100%"}
        }

    _getDescendantRows: (row) ->
        descendants = []

        collect = (node) ->
            _.each(node?.children or [], (child) ->
                descendants.push(child)
                collect(child)
            )

        collect(row)
        return descendants

    _getDependencySourceRows: (row) ->
        rowId = row?.rowId
        return [] if !rowId?

        sources = []
        seenRowIds = {}

        _.each(@sourceScheduleDependencies or [], (dependency) =>
            dependencyTargetRowId = null
            dependencyTargetScheduleId = @_normalizeId(dependency?.to_schedule)

            if dependencyTargetScheduleId?
                dependencyTargetRowId = @rowIdByScheduleId["#{dependencyTargetScheduleId}"]

            if !dependencyTargetRowId?
                dependencyTargetRowId = @_rowIdFromScheduleEntity(
                    dependency?.to_entity_type
                    dependency?.to_entity_id
                )

            return if dependencyTargetRowId != rowId

            sourceRowId = null
            sourceScheduleId = @_normalizeId(dependency?.from_schedule)

            if sourceScheduleId?
                sourceRowId = @rowIdByScheduleId["#{sourceScheduleId}"]

            if !sourceRowId?
                sourceRowId = @_rowIdFromScheduleEntity(
                    dependency?.from_entity_type
                    dependency?.from_entity_id
                )

            return if !sourceRowId? or sourceRowId == rowId
            return if seenRowIds[sourceRowId]

            sourceRow = @rowNodesById[sourceRowId]
            return if !sourceRow?

            seenRowIds[sourceRowId] = true
            sources.push(sourceRow)
        )

        return sources

    _buildResizeLimitData: (targetMoment, edge, timeline, relatedRowIds = []) ->
        return null if !targetMoment? or !timeline?

        slotIndex = @_findTimelineSlotIndexForMoment(targetMoment, timeline)
        position = if edge == "start" then slotIndex - 1 else slotIndex
        position = Math.max(0, Math.min(timeline.totalDays, position))

        return {
            slotIndex: slotIndex
            position: position
            relatedRowIds: relatedRowIds
        }

    _buildResizeLimits: (row, timeline) ->
        descendants = @_getDescendantRows(row)
        dependencySources = @_getDependencySourceRows(row)

        descendantRowIds = []
        dependencySourceRowIds = []
        earliestStartMoment = null
        latestDueMoment = null
        dependencyStartMinMoment = null

        _.each(descendants, (child) ->
            descendantRowIds.push(child.rowId) if child.rowId?

            if child.startMoment?
                if !earliestStartMoment? or child.startMoment.isBefore(earliestStartMoment, "day")
                    earliestStartMoment = child.startMoment.clone()

            if child.dueMoment?
                if !latestDueMoment? or child.dueMoment.isAfter(latestDueMoment, "day")
                    latestDueMoment = child.dueMoment.clone()
        )

        _.each(dependencySources, (sourceRow) ->
            dependencySourceRowIds.push(sourceRow.rowId) if sourceRow.rowId?
            return if !sourceRow.dueMoment?

            dependencyStartCandidate = sourceRow.dueMoment.clone().add(1, "day")
            if !dependencyStartMinMoment? or dependencyStartCandidate.isAfter(dependencyStartMinMoment, "day")
                dependencyStartMinMoment = dependencyStartCandidate
        )

        startLimit = @_buildResizeLimitData(earliestStartMoment, "start", timeline, descendantRowIds)
        endLimit = @_buildResizeLimitData(latestDueMoment, "end", timeline, descendantRowIds)
        dependencyStartLimit = @_buildResizeLimitData(
            dependencyStartMinMoment
            "start"
            timeline
            dependencySourceRowIds
        )

        return null if !startLimit? and !endLimit? and !dependencyStartLimit?

        return {
            descendantRowIds: descendantRowIds
            dependencySourceRowIds: dependencySourceRowIds
            start: startLimit
            end: endLimit
            dependencyStart: dependencyStartLimit
        }

    _getBarDetailUnits: (timeline, baseUnits) ->
        slotWidthRem = parseFloat(timeline?.slotWidthRem)
        slotWidthRem = @dayWidthRem if isNaN(slotWidthRem) or slotWidthRem <= 0

        return baseUnits * (@dayWidthRem / slotWidthRem)

    _buildBars: (rows, timeline) ->
        rowIndexesById = {}
        bars = []
        arrowDetailUnits = @_getBarDetailUnits(timeline, 0.28)
        cornerDetailUnits = @_getBarDetailUnits(timeline, 0.16)
        storyCapUnits = @_getBarDetailUnits(timeline, 0.18)

        _.each(rows or [], (row, index) ->
            rowIndexesById[row.rowId] = index
        )

        _.each(rows or [], (row) =>
            return if row.isPlaceholder
            return if !row.startMoment? or !row.dueMoment?

            barStartMoment = row.startMoment.clone()
            barEndMoment = row.dueMoment.clone()

            if barEndMoment.isBefore(barStartMoment)
                barEndMoment = barStartMoment.clone()

            startDay = @_findTimelineSlotIndexForMoment(barStartMoment, timeline)
            endDay = @_findTimelineSlotIndexForMoment(barEndMoment, timeline)
            startDay = Math.max(1, startDay)
            endDay = Math.max(startDay, endDay)

            rowIndex = rowIndexesById[row.rowId] or 0
            barType = row.type
            shape = if row.type == "task" then "rounded" else "arrow"

            bar = {
                rowId: row.rowId
                barType: barType
                shape: shape
                startDay: startDay
                endDay: endDay
                label: row.label
                canEdit: !!row.canEdit
                resizeLimits: @_buildResizeLimits(row, timeline)
                style: if row.barColor? then {fill: row.barColor} else {}
            }

            if shape == "rounded"
                bar.rect = @_buildRoundedRect(startDay, endDay, rowIndex, timeline.totalDays, cornerDetailUnits)
            else if barType == "story"
                bar.pathD = @_buildStoryPath(startDay, endDay, rowIndex, timeline.totalDays, storyCapUnits)
            else
                bar.pathD = @_buildEpicPath(startDay, endDay, rowIndex, timeline.totalDays, arrowDetailUnits)

            bars.push(bar)
        )

        return bars

    _buildEpicPath: (startDay, endDay, rowIndex, totalDays, detailUnits = 0.28) ->
        left = Math.max(0, startDay - 1)
        right = Math.min(totalDays, endDay)
        top = rowIndex + 0.22
        bottom = rowIndex + 0.58
        tip = rowIndex + 0.74
        span = Math.max(right - left, 0.5)
        inset = Math.min(detailUnits, span / 3)
        xRadius = Math.min(detailUnits * .9, span / 3)
        yRadius = Math.min(.17, (bottom - top) / 2)
        return "M#{left},#{top + yRadius}Q#{left},#{top} #{left + xRadius},#{top}L#{right - xRadius},#{top}Q#{right},#{top} #{right},#{top + yRadius}L#{right},#{bottom}L#{right},#{tip}L#{right - inset},#{bottom}L#{left + inset},#{bottom}L#{left},#{tip}L#{left},#{bottom}z"

    _buildStoryPath: (startDay, endDay, rowIndex, totalDays, capUnits = 0.18) ->
        left = Math.max(0, startDay - 1)
        right = Math.min(totalDays, endDay)
        top = rowIndex + 0.22
        bottom = rowIndex + 0.58
        span = Math.max(right - left, 0.5)
        yRadius = (bottom - top) / 2
        xRadius = Math.min(capUnits, span / 2)
        innerLeft = left + xRadius
        innerRight = right - xRadius
        return "M#{innerLeft},#{top}L#{innerRight},#{top}A#{xRadius},#{yRadius} 0 0 1 #{innerRight},#{bottom}L#{innerLeft},#{bottom}A#{xRadius},#{yRadius} 0 0 1 #{innerLeft},#{top}z"

    _buildRoundedRect: (startDay, endDay, rowIndex, totalDays, cornerUnits = 0.16) ->
        left = Math.max(0, startDay - 1)
        right = Math.min(totalDays, endDay)
        width = Math.max(right - left, .35)
        rx = Math.min(cornerUnits, width / 2)
        return {
            x: left
            y: rowIndex + 0.28
            width: width
            height: 0.50
            rx: rx
            ry: 0.16
        }

module.controller("GanttController", GanttController)

GANTT_LAYOUT_COOKIE_MAX_AGE = 60 * 60 * 24 * 365

getGanttCookieProjectId = ($scope) ->
    projectId = $scope?.projectId or $scope?.project?.id
    return "global" if !projectId?
    return "#{projectId}"

buildGanttCookieName = (key, $scope) ->
    projectId = getGanttCookieProjectId($scope)
    return "taiga_gantt_#{key}_#{projectId}"

readGanttCookie = (name) ->
    return null if typeof document == "undefined" or !name?

    rawCookies = document.cookie or ""
    cookiePairs = rawCookies.split(";")

    for rawPair in cookiePairs
        pair = rawPair.trim()
        continue if !pair.length

        separatorIndex = pair.indexOf("=")
        continue if separatorIndex == -1

        cookieName = pair.substring(0, separatorIndex)
        continue if cookieName != name

        cookieValue = pair.substring(separatorIndex + 1)

        try
            return decodeURIComponent(cookieValue)
        catch error
            return cookieValue

    return null

writeGanttCookie = (name, value) ->
    return if typeof document == "undefined" or !name?

    encodedValue = encodeURIComponent("#{value or ''}")
    document.cookie = "#{name}=#{encodedValue}; max-age=#{GANTT_LAYOUT_COOKIE_MAX_AGE}; path=/; SameSite=Lax"
    return

readGanttJsonCookie = (name) ->
    rawValue = readGanttCookie(name)
    return null if !rawValue?

    try
        return JSON.parse(rawValue)
    catch error
        return null

writeGanttJsonCookie = (name, value) ->
    return if !value?

    try
        serialized = JSON.stringify(value)
    catch error
        return

    writeGanttCookie(name, serialized)
    return

GanttColumnResizeDirective = ($document) ->
    link = ($scope, $el) ->
        root = $el[0]
        header = root.querySelector(".gantt-table-header")
        return if !header?

        minWidths = {
            item: 180
            assignee: 110
            eh: 60
            start: 85
            due: 85
            progress: 85
        }

        active = null
        cookieName = buildGanttCookieName("layout_columns", $scope)

        getColumnVar = (key) -> "--gantt-col-#{key}"

        getHeaderCellByKey = (key) ->
            handle = header.querySelector(".gantt-col-resizer[data-gantt-resize=\"#{key}\"]")
            return null if !handle?
            return handle.closest(".gantt-col-header")

        updateTableWidth = ->
            headerCells = Array.from(header.querySelectorAll(".gantt-col-header"))
            return if headerCells.length == 0

            cellsWidth = headerCells.reduce(((sum, cell) -> sum + cell.getBoundingClientRect().width), 0)
            headerStyles = window.getComputedStyle(header)
            columnGap = parseFloat(headerStyles.columnGap or "0") or 0
            paddingLeft = parseFloat(headerStyles.paddingLeft or "0") or 0
            paddingRight = parseFloat(headerStyles.paddingRight or "0") or 0

            tableWidth = Math.ceil(cellsWidth + (columnGap * Math.max(headerCells.length - 1, 0)) + paddingLeft + paddingRight)
            root.style.setProperty("--gantt-table-width", "#{tableWidth}px")

        persistColumnWidths = ->
            widths = {}

            _.each(_.keys(minWidths), (key) ->
                headerCell = getHeaderCellByKey(key)
                return if !headerCell?

                width = Math.round(headerCell.getBoundingClientRect().width)
                return if !isFinite(width) or width <= 0

                widths[key] = width
            )

            return if _.isEmpty(widths)
            writeGanttJsonCookie(cookieName, widths)

        applyPersistedColumnWidths = ->
            persisted = readGanttJsonCookie(cookieName)
            return if !persisted? or !_.isObject(persisted)

            hasApplied = false

            _.each(_.keys(minWidths), (key) ->
                rawWidth = parseFloat(persisted[key])
                return if isNaN(rawWidth)

                minWidth = minWidths[key] or 80
                nextWidth = Math.max(minWidth, Math.round(rawWidth))
                root.style.setProperty(getColumnVar(key), "#{nextWidth}px")
                hasApplied = true
            )

            updateTableWidth() if hasApplied

        onMouseMove = (event) ->
            return if !active?

            deltaX = event.clientX - active.startX
            minWidth = minWidths[active.key] or 80
            nextWidth = Math.max(minWidth, Math.round(active.startWidth + deltaX))

            root.style.setProperty(getColumnVar(active.key), "#{nextWidth}px")
            updateTableWidth()

        stopDrag = ->
            return if !active?

            persistColumnWidths()
            active = null
            root.classList.remove("is-resizing-columns")
            $document.off("mousemove", onMouseMove)
            $document.off("mouseup", stopDrag)

        startDrag = (event) ->
            handle = event.currentTarget
            key = handle.getAttribute("data-gantt-resize")
            headerCell = handle.closest(".gantt-col-header")
            return if !key? or !headerCell?

            event.preventDefault()
            event.stopPropagation()

            active = {
                key: key
                startX: event.clientX
                startWidth: headerCell.getBoundingClientRect().width
            }

            root.classList.add("is-resizing-columns")
            $document.on("mousemove", onMouseMove)
            $document.on("mouseup", stopDrag)

        handles = Array.from(header.querySelectorAll(".gantt-col-resizer[data-gantt-resize]"))
        handles.forEach (handle) ->
            angular.element(handle).on("mousedown", startDrag)

        $scope.$evalAsync ->
            applyPersistedColumnWidths()
            updateTableWidth()

        $scope.$on "$destroy", ->
            handles.forEach (handle) ->
                angular.element(handle).off("mousedown", startDrag)

            stopDrag()

    return {link: link}

module.directive("tgGanttColumnResize", ["$document", GanttColumnResizeDirective])

GanttPanelResizeDirective = ($document) ->
    link = ($scope, $el) ->
        workspace = $el[0]
        leftPanel = workspace.querySelector(".gantt-left-panel")
        rightPanel = workspace.querySelector(".gantt-right-panel")
        handle = workspace.querySelector(".gantt-panel-resizer")
        return if !leftPanel? or !rightPanel? or !handle?

        active = null
        cookieName = buildGanttCookieName("layout_panel_width", $scope)

        getMinWidth = (node) ->
            minWidth = parseFloat(window.getComputedStyle(node).minWidth or "")
            if isNaN(minWidth) then 0 else minWidth

        setLeftWidth = (requestedWidth, persist = false) ->
            workspaceRect = workspace.getBoundingClientRect()
            handleWidth = handle.getBoundingClientRect().width or 0
            workspaceWidth = workspaceRect.width or 0
            minLeft = getMinWidth(leftPanel)
            minRight = getMinWidth(rightPanel)

            maxLeft = workspaceWidth - minRight - handleWidth
            return if maxLeft <= 0

            minAllowed = Math.min(minLeft, maxLeft)
            bounded = Math.max(minAllowed, Math.min(maxLeft, requestedWidth))
            return if !isFinite(bounded)

            rounded = Math.round(bounded)
            workspace.style.setProperty("--gantt-left-panel-width", "#{rounded}px")
            writeGanttCookie(cookieName, rounded) if persist

        onMouseMove = (event) ->
            return if !active?

            rect = workspace.getBoundingClientRect()
            handleWidth = active.handleWidth or 0
            nextWidth = event.clientX - rect.left - (handleWidth / 2)
            setLeftWidth(nextWidth)

        stopDrag = ->
            return if !active?

            setLeftWidth(leftPanel.getBoundingClientRect().width, true)
            active = null
            workspace.classList.remove("is-resizing-panels")
            $document.off("mousemove", onMouseMove)
            $document.off("mouseup", stopDrag)

        startDrag = (event) ->
            event.preventDefault()
            event.stopPropagation()

            active = {
                handleWidth: handle.getBoundingClientRect().width or 0
            }

            workspace.classList.add("is-resizing-panels")
            $document.on("mousemove", onMouseMove)
            $document.on("mouseup", stopDrag)

        onKeydown = (event) ->
            leftKey = event.key == "ArrowLeft" or event.keyCode == 37
            rightKey = event.key == "ArrowRight" or event.keyCode == 39
            return if !leftKey and !rightKey

            event.preventDefault()
            step = if event.shiftKey then 32 else 16
            currentWidth = leftPanel.getBoundingClientRect().width
            delta = if leftKey then -step else step
            setLeftWidth(currentWidth + delta, true)

        handleEl = angular.element(handle)
        handleEl.on("mousedown", startDrag)
        handleEl.on("keydown", onKeydown)

        $scope.$evalAsync ->
            persistedWidth = parseFloat(readGanttCookie(cookieName) or "")

            if !isNaN(persistedWidth)
                setLeftWidth(persistedWidth, true)
            else
                setLeftWidth(leftPanel.getBoundingClientRect().width, true)

        $scope.$on "$destroy", ->
            handleEl.off("mousedown", startDrag)
            handleEl.off("keydown", onKeydown)
            stopDrag()

    return {link: link}

module.directive("tgGanttPanelResize", ["$document", GanttPanelResizeDirective])

GanttSyncRowsDirective = ->
    link = ($scope, $el) ->
        root = $el[0]
        leftPanel = root.querySelector(".gantt-left-panel")
        rightPanel = root.querySelector(".gantt-right-panel")
        return if !leftPanel?

        isSyncingScroll = false

        syncVerticalScroll = (source, target) ->
            return if !source? or !target?
            return if isSyncingScroll
            return if source.scrollTop == target.scrollTop

            isSyncingScroll = true
            target.scrollTop = source.scrollTop
            isSyncingScroll = false

        onLeftScroll = ->
            syncVerticalScroll(leftPanel, rightPanel)

        onRightScroll = ->
            syncVerticalScroll(rightPanel, leftPanel)

        updateRightPanelOverflow = (visibleRows = []) ->
            return if !rightPanel?

            monthsHeader = rightPanel.querySelector(".gantt-timeline-months")
            daysHeader = rightPanel.querySelector(".gantt-timeline-days")

            monthsHeaderHeight = monthsHeader?.getBoundingClientRect().height or 0
            daysHeaderHeight = daysHeader?.getBoundingClientRect().height or 0
            availableRowsHeight = Math.max(0, (rightPanel.clientHeight or 0) - monthsHeaderHeight - daysHeaderHeight)

            rowHeight = 0
            if visibleRows.length
                rowHeight = visibleRows[0].getBoundingClientRect().height or 0

            if rowHeight <= 0
                sampleRow = leftPanel.querySelector(".gantt-tree-row")
                rowHeight = sampleRow?.getBoundingClientRect().height or 0

            requiredRowsHeight = visibleRows.length * rowHeight
            hasVerticalOverflow = requiredRowsHeight > (availableRowsHeight + 1)

            rightPanel.classList.toggle("has-vertical-scroll", hasVerticalOverflow)

            if !hasVerticalOverflow
                rightPanel.scrollTop = 0
                leftPanel.scrollTop = 0

        onLeftWheel = (event) ->
            return if !rightPanel?

            deltaY = event.deltaY or 0
            deltaX = event.deltaX or 0
            return if deltaY == 0 and deltaX == 0

            # Keep a single vertical scrollbar (right panel),
            # but let horizontal scrolling remain local on the left panel.
            isHorizontalIntent = Math.abs(deltaX) > Math.abs(deltaY)
            return if isHorizontalIntent
            return if !rightPanel.classList.contains("has-vertical-scroll")

            nextTop = rightPanel.scrollTop + deltaY
            rightPanel.scrollTop = nextTop if deltaY != 0
            syncVerticalScroll(rightPanel, leftPanel)
            event.preventDefault()

        getBarsData = ->
            barsSvg = root.querySelector(".gantt-bars-svg")
            bars = if barsSvg? then Array.from(root.querySelectorAll(".gantt-bar[data-gantt-row-id]:not(.gantt-bar-create-preview)")) else []

            return {
                barsSvg: barsSvg
                bars: bars
            }

        getBarsModelByRowId = ->
            modelByRowId = {}
            _.each($scope.ctrl?.ganttBars or [], (barModel) ->
                return if !barModel?.rowId?
                modelByRowId["#{barModel.rowId}"] = barModel
            )
            return modelByRowId

        getBarDetailUnits = (baseUnits) ->
            baseSlotWidthRem = parseFloat($scope.ctrl?.dayWidthRem or "2.2")
            baseSlotWidthRem = 2.2 if isNaN(baseSlotWidthRem) or baseSlotWidthRem <= 0

            slotWidthRem = parseFloat($scope.ctrl?.timeline?.slotWidthRem or "#{baseSlotWidthRem}")
            slotWidthRem = baseSlotWidthRem if isNaN(slotWidthRem) or slotWidthRem <= 0

            return baseUnits * (baseSlotWidthRem / slotWidthRem)

        buildEpicPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            tip = rowIndex + 0.74
            span = Math.max(right - left, 0.5)
            inset = Math.min(getBarDetailUnits(0.28), span / 3)
            xRadius = Math.min(getBarDetailUnits(0.25), span / 3)
            yRadius = Math.min(.17, (bottom - top) / 2)
            "M#{left},#{top + yRadius}Q#{left},#{top} #{left + xRadius},#{top}L#{right - xRadius},#{top}Q#{right},#{top} #{right},#{top + yRadius}L#{right},#{bottom}L#{right},#{tip}L#{right - inset},#{bottom}L#{left + inset},#{bottom}L#{left},#{tip}L#{left},#{bottom}z"

        buildStoryPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            span = Math.max(right - left, 0.5)
            yRadius = (bottom - top) / 2
            xRadius = Math.min(getBarDetailUnits(0.18), span / 2)
            innerLeft = left + xRadius
            innerRight = right - xRadius
            "M#{innerLeft},#{top}L#{innerRight},#{top}A#{xRadius},#{yRadius} 0 0 1 #{innerRight},#{bottom}L#{innerLeft},#{bottom}A#{xRadius},#{yRadius} 0 0 1 #{innerLeft},#{top}z"

        buildRoundedRect = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            width = Math.max(right - left, .35)
            rx = Math.min(getBarDetailUnits(0.16), width / 2)
            {
                x: left
                y: rowIndex + 0.28
                width: width
                height: 0.50
                rx: rx
                ry: 0.16
            }

        normalizeRowReferenceId = (value) ->
            return null if !value?

            if _.isObject(value)
                return normalizeRowReferenceId(value.id) if value.id?
                return null

            numericValue = parseInt(value, 10)
            return numericValue if !isNaN(numericValue)
            return "#{value}"

        getParentRowId = (rowId) ->
            row = $scope.ctrl?.rowNodesById?[rowId]
            return null if !row?

            if row.type == "task"
                storyId = normalizeRowReferenceId(row.item?.user_story) or normalizeRowReferenceId(row.item?.user_story_extra_info?.id)
                return "story-#{storyId}" if storyId?
                return null

            if row.type == "story"
                epicId = normalizeRowReferenceId(row.epicId)
                return "epic-#{epicId}" if epicId?
                return null

            return null

        isBarVisibleInTimeline = (bar) ->
            return false if !bar?
            return false if bar.classList.contains("is-hidden")
            return false if bar.getAttribute("data-sync-hidden") == "true"
            return false if bar.getAttribute("visibility") == "hidden"
            return true

        resolveVisibleSourceBar = (sourceRowId, barsByRowId) ->
            currentRowId = sourceRowId
            depth = 0

            while currentRowId?
                bar = barsByRowId[currentRowId]
                if isBarVisibleInTimeline(bar)
                    return {
                        rowId: currentRowId
                        bar: bar
                        depth: depth
                    }

                currentRowId = getParentRowId(currentRowId)
                depth += 1

            return null

        getSourceAnchorEndDay = (sourceRowId, fallbackBar, barsModelByRowId = {}) ->
            barModel = barsModelByRowId[sourceRowId]
            endDay = parseFloat(barModel?.endDay)
            return endDay if isFinite(endDay) and endDay > 0

            fallbackEndDay = parseFloat(fallbackBar?.getAttribute("data-end-day") or "0")
            return fallbackEndDay if isFinite(fallbackEndDay) and fallbackEndDay > 0

            return null

        getBarBottomAnchorY = (bar, rowIndex) ->
            shape = bar?.getAttribute("data-shape") or ""
            barType = bar?.getAttribute("data-bar-type") or ""

            return rowIndex + 0.78 if shape == "rounded"
            return rowIndex + 0.64 if barType == "epic"
            return rowIndex + 0.64 if barType == "story"
            return rowIndex + 0.58

        getBarTopAnchorY = (bar, rowIndex) ->
            shape = bar?.getAttribute("data-shape") or ""
            barType = bar?.getAttribute("data-bar-type") or ""

            return rowIndex + 0.28 if shape == "rounded"
            return rowIndex + 0.17 if barType == "epic"
            return rowIndex + 0.16 if barType == "story"
            return rowIndex + 0.22

        buildTreeRowOrderById = ->
            orderById = {}
            nextIndex = 0

            walk = (node) ->
                return if !node?.rowId?
                orderById[node.rowId] = nextIndex
                nextIndex += 1
                _.each(node.children or [], (child) ->
                    walk(child)
                )

            _.each($scope.ctrl?.tree or [], (rootNode) ->
                walk(rootNode)
            )

            return orderById

        buildPromotedSourceStemPath = (sourceX, sourceY, depth, direction = "down") ->
            stemDepth = Math.max(1, depth)
            stemLength = 0.38 + ((stemDepth - 1) * 0.16)
            stemStartY = if direction == "up" then sourceY - stemLength else sourceY + stemLength
            return "M#{sourceX},#{stemStartY}L#{sourceX},#{sourceY}"

        mergePromotedStemWithRoute = (promotedStemPath, routePath) ->
            return promotedStemPath if !routePath?

            firstLineCommandIndex = routePath.indexOf("L")
            return promotedStemPath if firstLineCommandIndex < 0

            routeContinuation = routePath.substring(firstLineCommandIndex)
            return "#{promotedStemPath}#{routeContinuation}"

        buildDirectLinkRoute = (sourceX, sourceY, targetX, targetY, totalDays, turnGap) ->
            turnX = Math.min(totalDays, sourceX + turnGap)
            verticalDelta = targetY - sourceY

            if Math.abs(verticalDelta) <= 0.001
                return {
                    direction: if targetX >= sourceX then 1 else -1
                    path: "M#{sourceX},#{sourceY}L#{targetX},#{targetY}"
                }

            return {
                direction: if targetX >= sourceX then 1 else -1
                path: "M#{sourceX},#{sourceY}L#{turnX},#{sourceY}L#{turnX},#{targetY}L#{targetX},#{targetY}"
            }

        buildCloseLinkRoute = (sourceX, sourceY, targetX, targetTopY, targetBottomY, targetY, totalDays, xScale, yScale, targetTipGapY = null) ->
            targetTipGap = if isFinite(targetTipGapY) and targetTipGapY > 0 then targetTipGapY else (5 / yScale)
            targetTipY = if sourceY <= targetY
                Math.max(0, targetTopY - targetTipGap)
            else
                targetBottomY + targetTipGap
            verticalDelta = targetTipY - sourceY

            if Math.abs(verticalDelta) <= 0.001
                return {
                    direction: "right"
                    tipX: targetX
                    tipY: targetTipY
                    path: "M#{sourceX},#{sourceY}L#{targetX},#{targetTipY}"
                }

            verticalDirection = if verticalDelta >= 0 then 1 else -1
            path = "M#{sourceX},#{sourceY}L#{targetX},#{sourceY}L#{targetX},#{targetTipY}"

            return {
                direction: if verticalDirection > 0 then "down" else "up"
                tipX: targetX
                tipY: targetTipY
                path: path
            }

        buildLinkRoute = (sourceX, sourceY, targetX, targetY, targetTopY, targetBottomY, totalDays, xScale, yScale, targetTipGapY = null) ->
            closeTurnGap = getBarDetailUnits(0.3)
            shouldUseCloseRoute = Math.abs(targetY - sourceY) > 0.001 and targetX - sourceX <= closeTurnGap
            if shouldUseCloseRoute
                closeTargetX = Math.min(totalDays, sourceX + closeTurnGap)
                return buildCloseLinkRoute(sourceX, sourceY, closeTargetX, targetTopY, targetBottomY, targetY, totalDays, xScale, yScale, targetTipGapY)

            route = buildDirectLinkRoute(sourceX, sourceY, targetX, targetY, totalDays, closeTurnGap)
            route.tipX = targetX
            route.tipY = targetY
            return route

        buildPromotedLinkRoute = (sourceX, sourceY, targetX, targetY, targetTopY, targetBottomY, totalDays, xScale, yScale, targetTipGapY = null) ->
            closeTurnGap = getBarDetailUnits(0.3)
            shouldUseCloseRoute = Math.abs(targetY - sourceY) > 0.001 and targetX - sourceX <= closeTurnGap

            if shouldUseCloseRoute
                targetTipGap = if isFinite(targetTipGapY) and targetTipGapY > 0 then targetTipGapY else (5 / yScale)
                targetTipY = if sourceY <= targetY
                    Math.max(0, targetTopY - targetTipGap)
                else
                    targetBottomY + targetTipGap

                verticalDirection = if targetTipY >= sourceY then 1 else -1
                return {
                    direction: if verticalDirection > 0 then "down" else "up"
                    tipX: sourceX
                    tipY: targetTipY
                    path: "M#{sourceX},#{sourceY}L#{sourceX},#{targetTipY}"
                }

            if Math.abs(targetY - sourceY) <= 0.001
                return {
                    direction: if targetX >= sourceX then 1 else -1
                    tipX: targetX
                    tipY: targetY
                    path: "M#{sourceX},#{sourceY}L#{targetX},#{targetY}"
                }

            hasHorizontalTail = Math.abs(targetX - sourceX) > 0.001
            path = "M#{sourceX},#{sourceY}L#{sourceX},#{targetY}"
            path = "#{path}L#{targetX},#{targetY}" if hasHorizontalTail

            return {
                direction: if hasHorizontalTail then (if targetX >= sourceX then 1 else -1) else (if targetY >= sourceY then "down" else "up")
                tipX: if hasHorizontalTail then targetX else sourceX
                tipY: targetY
                path: path
            }

        buildArrowheadPath = (tipX, tipY, direction, xScale, yScale) ->
            arrowHeadBackX = 5 / xScale
            arrowHalfHeightY = 5 / yScale
            arrowHeadBackY = 5 / yScale
            arrowHalfWidthX = 5 / xScale

            if direction == "down" or direction == "up"
                verticalDirection = if direction == "down" then 1 else -1
                headBaseY = tipY - (verticalDirection * arrowHeadBackY)
                return "M#{tipX - arrowHalfWidthX},#{headBaseY}L#{tipX},#{tipY}L#{tipX + arrowHalfWidthX},#{headBaseY}"

            horizontalDirection = if direction == "left" or direction == -1 then -1 else 1
            headBaseX = tipX - (horizontalDirection * arrowHeadBackX)

            return "M#{headBaseX},#{tipY - arrowHalfHeightY}L#{tipX},#{tipY}L#{headBaseX},#{tipY + arrowHalfHeightY}"

        syncLinks = (barsSvg, barsByRowId, barsModelByRowId, totalDays, visibleRowsCount) ->
            return if !barsSvg?

            linkPaths = Array.from(barsSvg.querySelectorAll(".gantt-link-path[data-link-id][data-source-row-id][data-target-row-id]"))
            arrowheads = Array.from(barsSvg.querySelectorAll(".gantt-link-arrowhead[data-link-id]"))
            sourceCaps = Array.from(barsSvg.querySelectorAll(".gantt-link-source-cap[data-link-id]"))
            arrowheadsByLinkId = {}
            sourceCapsByLinkId = {}
            _.each(arrowheads, (arrowhead) ->
                linkId = arrowhead.getAttribute("data-link-id")
                arrowheadsByLinkId[linkId] = arrowhead if linkId?
            )
            _.each(sourceCaps, (sourceCap) ->
                linkId = sourceCap.getAttribute("data-link-id")
                sourceCapsByLinkId[linkId] = sourceCap if linkId?
            )
            endpointGap = getBarDetailUnits(0.08)
            svgRect = barsSvg.getBoundingClientRect()
            xScale = svgRect.width / totalDays
            yScale = svgRect.height / Math.max(1, visibleRowsCount)
            rowOrderById = buildTreeRowOrderById()

            hideLink = (linkPath, arrowhead, sourceCap) ->
                linkPath.classList.add("is-hidden")
                linkPath.setAttribute("data-sync-hidden", "true")
                linkPath.setAttribute("visibility", "hidden")
                arrowhead?.classList?.add("is-hidden")
                arrowhead?.setAttribute("data-sync-hidden", "true")
                arrowhead?.setAttribute("visibility", "hidden")
                sourceCap?.classList?.remove("is-visible")
                sourceCap?.classList?.add("is-hidden")
                sourceCap?.setAttribute("data-sync-hidden", "true")
                sourceCap?.setAttribute("visibility", "hidden")

            if !isFinite(xScale) or !isFinite(yScale) or xScale <= 0 or yScale <= 0
                _.each(linkPaths, (linkPath) ->
                    linkId = linkPath.getAttribute("data-link-id")
                    hideLink(linkPath, arrowheadsByLinkId[linkId], sourceCapsByLinkId[linkId])
                )
                return

            linkPaths.forEach (linkPath) ->
                linkId = linkPath.getAttribute("data-link-id")
                arrowhead = arrowheadsByLinkId[linkId]
                sourceCap = sourceCapsByLinkId[linkId]
                sourceRowId = linkPath.getAttribute("data-source-row-id")
                targetRowId = linkPath.getAttribute("data-target-row-id")
                sourceResolution = resolveVisibleSourceBar(sourceRowId, barsByRowId)
                sourceBar = sourceResolution?.bar
                targetBar = barsByRowId[targetRowId]

                if !sourceBar? or !targetBar? or !arrowhead? or !sourceCap?
                    hideLink(linkPath, arrowhead, sourceCap)
                    return

                sourceEndDay = getSourceAnchorEndDay(sourceRowId, sourceBar, barsModelByRowId)
                targetStartDay = parseFloat(targetBar.getAttribute("data-start-day") or "1")
                sourceRowIndex = parseFloat(sourceBar.getAttribute("data-row-index") or "0")
                targetRowIndex = parseFloat(targetBar.getAttribute("data-row-index") or "0")

                if !isFinite(sourceEndDay) or !isFinite(targetStartDay) or !isFinite(sourceRowIndex) or !isFinite(targetRowIndex)
                    hideLink(linkPath, arrowhead, sourceCap)
                    return

                targetShape = targetBar.getAttribute("data-shape") or ""
                targetBarType = targetBar.getAttribute("data-bar-type") or ""
                targetEndpointGap = endpointGap
                if targetBarType == "story"
                    targetEndpointGap += getBarDetailUnits(0.06)
                if targetShape == "rounded"
                    targetEndpointGap += (2 / xScale)
                targetTipGapY = (5 / yScale)
                if targetShape == "rounded" or targetBarType == "story"
                    targetTipGapY += (2 / yScale)

                sourceX = Math.min(totalDays, sourceEndDay + endpointGap)
                sourceOrder = rowOrderById[sourceRowId]
                targetOrder = rowOrderById[targetRowId]
                isSourceBelowTarget = _.isNumber(sourceOrder) and _.isNumber(targetOrder) and sourceOrder > targetOrder
                sourceY = if sourceResolution.depth > 0
                    if isSourceBelowTarget then getBarTopAnchorY(sourceBar, sourceRowIndex) else getBarBottomAnchorY(sourceBar, sourceRowIndex)
                else
                    sourceRowIndex + 0.5
                targetX = Math.max(0, targetStartDay - 1 - targetEndpointGap)
                targetY = targetRowIndex + 0.5
                targetTopOffset = if targetShape == "rounded" then 0.28 else 0.22
                targetBottomOffset = if targetShape == "rounded" then 0.78 else if targetBarType == "epic" then 0.74 else 0.58
                targetTopY = targetRowIndex + targetTopOffset
                targetBottomY = targetRowIndex + targetBottomOffset
                linkRoute = if sourceResolution.depth > 0
                    buildPromotedLinkRoute(sourceX, sourceY, targetX, targetY, targetTopY, targetBottomY, totalDays, xScale, yScale, targetTipGapY)
                else
                    buildLinkRoute(sourceX, sourceY, targetX, targetY, targetTopY, targetBottomY, totalDays, xScale, yScale, targetTipGapY)
                sourceCapHalfHeightY = 4 / yScale
                sourceCapHalfWidthX = 4 / xScale
                linkPathD = linkRoute.path

                if sourceResolution.depth > 0
                    stemDirection = if isSourceBelowTarget then "up" else "down"
                    promotedStemPath = buildPromotedSourceStemPath(sourceX, sourceY, sourceResolution.depth, stemDirection)
                    linkPathD = mergePromotedStemWithRoute(promotedStemPath, linkRoute.path)

                linkPath.setAttribute("d", linkPathD)
                arrowhead.setAttribute("d", buildArrowheadPath(linkRoute.tipX, linkRoute.tipY, linkRoute.direction, xScale, yScale))
                sourceCapPath = if sourceResolution.depth > 0
                    "M#{sourceX - sourceCapHalfWidthX},#{sourceY}L#{sourceX + sourceCapHalfWidthX},#{sourceY}"
                else
                    "M#{sourceX},#{sourceY - sourceCapHalfHeightY}L#{sourceX},#{sourceY + sourceCapHalfHeightY}"
                sourceCap.setAttribute("d", sourceCapPath)
                linkPath.classList.remove("is-hidden")
                arrowhead.classList.remove("is-hidden")
                sourceCap.classList.remove("is-hidden")
                linkPath.removeAttribute("data-sync-hidden")
                arrowhead.removeAttribute("data-sync-hidden")
                sourceCap.removeAttribute("data-sync-hidden")
                linkPath.setAttribute("visibility", "visible")
                arrowhead.setAttribute("visibility", "visible")
                sourceCap.setAttribute("visibility", "visible")

        syncBars = (visibleRowMap, visibleRowsCount) ->
            barsData = getBarsData()
            barsSvg = barsData.barsSvg
            bars = barsData.bars
            return if !barsSvg?

            barsModelByRowId = getBarsModelByRowId()
            barsByRowId = {}

            totalDays = parseFloat(barsSvg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)
            barsSvg.setAttribute("viewBox", "0 0 #{totalDays} #{Math.max(1, visibleRowsCount)}")

            bars.forEach (bar) ->
                rowId = bar.getAttribute("data-gantt-row-id")
                rowIndex = visibleRowMap[rowId]

                if rowIndex == undefined
                    bar.classList.add("is-hidden")
                    bar.setAttribute("data-sync-hidden", "true")
                    bar.setAttribute("visibility", "hidden")
                    bar.removeAttribute("data-row-index")
                    return

                barModel = barsModelByRowId[rowId]
                startDay = if barModel?.startDay? then parseFloat(barModel.startDay) else parseFloat(bar.getAttribute("data-start-day") or "1")
                startDay = 1 if !isFinite(startDay) or startDay <= 0

                endDay = if barModel?.endDay? then parseFloat(barModel.endDay) else parseFloat(bar.getAttribute("data-end-day") or "#{startDay}")
                endDay = startDay if !isFinite(endDay) or endDay < startDay

                shape = barModel?.shape or bar.getAttribute("data-shape") or "arrow"
                barType = barModel?.barType or bar.getAttribute("data-bar-type") or ""
                bar.setAttribute("data-row-index", rowIndex)
                bar.setAttribute("data-start-day", startDay)
                bar.setAttribute("data-end-day", endDay)
                bar.setAttribute("data-shape", shape)
                bar.setAttribute("data-bar-type", barType)

                if shape == "rounded"
                    rounded = buildRoundedRect(startDay, endDay, rowIndex, totalDays)
                    bar.setAttribute("x", rounded.x)
                    bar.setAttribute("y", rounded.y)
                    bar.setAttribute("width", rounded.width)
                    bar.setAttribute("height", rounded.height)
                    bar.setAttribute("rx", rounded.rx)
                    bar.setAttribute("ry", rounded.ry)
                else
                    path = if barType == "story" then buildStoryPath(startDay, endDay, rowIndex, totalDays) else buildEpicPath(startDay, endDay, rowIndex, totalDays)
                    bar.setAttribute("d", path)

                bar.classList.remove("is-hidden")
                bar.removeAttribute("data-sync-hidden")
                bar.setAttribute("visibility", "visible")
                barsByRowId[rowId] = bar

            syncLinks(barsSvg, barsByRowId, barsModelByRowId, totalDays, visibleRowsCount)

        updateVisibleRows = ->
            rows = Array.from(leftPanel.querySelectorAll(".gantt-tree-row"))
            visibleRows = rows.filter((row) -> row.offsetParent?)
            visibleRowMap = {}

            visibleRows.forEach (row, index) ->
                rowId = row.getAttribute("data-gantt-row-id")
                return if !rowId?
                visibleRowMap[rowId] = index

            visibleRowsCount = Math.max(visibleRows.length, 1)
            root.style.setProperty("--gantt-visible-rows", "#{visibleRowsCount}")
            syncBars(visibleRowMap, visibleRowsCount)
            updateRightPanelOverflow(visibleRows)

        onChange = (event) ->
            target = event.target
            return if !target?.classList?.contains("gantt-node-trigger")
            updateVisibleRows()

        observer = null
        scheduleUpdate = _.debounce(updateVisibleRows, 0)
        onWindowResize = _.debounce(updateVisibleRows, 25)
        unwatchBars = $scope.$watchCollection("ctrl.ganttBars", ->
            _.defer(scheduleUpdate)
        )
        unwatchBarLinks = $scope.$watchCollection("ctrl.barLinks", ->
            _.defer(scheduleUpdate)
        )
        unwatchTimelineStart = $scope.$watch("ctrl.timeline.start", ->
            _.defer(scheduleUpdate)
        )
        unwatchTimelineDays = $scope.$watch("ctrl.timeline.totalDays", ->
            _.defer(scheduleUpdate)
        )
        unwatchForcedSyncRows = $scope.$on("tg:gantt-sync-rows-now", ->
            updateVisibleRows()
        )

        isResizeOverlayMutation = (mutation) ->
            node = mutation?.target

            while node? and node != root
                return true if node.classList?.contains("gantt-edge-indicator")
                return true if node.classList?.contains("gantt-resize-limit-indicator")
                return true if node.classList?.contains("gantt-bar-resize-popup")
                return true if node.classList?.contains("gantt-bar-create-preview")
                node = node.parentNode

            return false

        if window.MutationObserver?
            observer = new MutationObserver (mutations) ->
                return if root.classList.contains("is-resizing-gantt-bar")
                return if root.classList.contains("is-moving-gantt-bar")
                return if root.classList.contains("is-creating-gantt-bar")

                shouldUpdate = _.some(mutations or [], (mutation) ->
                    return !isResizeOverlayMutation(mutation)
                )
                return if !shouldUpdate

                scheduleUpdate()

            observer.observe(leftPanel, {childList: true, subtree: true})
            if rightPanel?
                observer.observe(rightPanel, {childList: true, subtree: true})

        leftPanel.addEventListener("scroll", onLeftScroll)
        leftPanel.addEventListener("wheel", onLeftWheel)
        rightPanel.addEventListener("scroll", onRightScroll) if rightPanel?
        leftPanel.addEventListener("change", onChange)
        window.addEventListener("resize", onWindowResize)
        $scope.$evalAsync(updateVisibleRows)

        $scope.$on "$destroy", ->
            leftPanel.removeEventListener("scroll", onLeftScroll)
            leftPanel.removeEventListener("wheel", onLeftWheel)
            rightPanel.removeEventListener("scroll", onRightScroll) if rightPanel?
            leftPanel.removeEventListener("change", onChange)
            window.removeEventListener("resize", onWindowResize)
            observer.disconnect() if observer?
            unwatchBars?()
            unwatchBarLinks?()
            unwatchTimelineStart?()
            unwatchTimelineDays?()
            unwatchForcedSyncRows?()

    return {link: link}

module.directive("tgGanttSyncRows", [GanttSyncRowsDirective])

GanttTreeReorderDirective = ($document) ->
    link = ($scope, $el) ->
        root = $el[0]
        leftPanel = root.querySelector(".gantt-left-panel")
        return if !leftPanel?

        HANDLE_SELECTOR = ".gantt-tree-reorder-handle"
        DRAG_GHOST_POINTER_INSET_X = 10
        DRAG_GHOST_POINTER_INSET_Y = 17
        HANDLE_HOVER_CLASS = "is-hovering-tree-reorder-handle"
        DRAG_CLASS = "is-dragging-gantt-tree-row"
        active = null

        dragGhost = document.createElement("div")
        dragGhost.setAttribute("class", "gantt-tree-row-drag-ghost")
        dragGhost.style.display = "none"
        dragGhost.style.left = "-9999px"
        dragGhost.style.pointerEvents = "none"
        dragGhost.style.position = "fixed"
        dragGhost.style.top = "-9999px"
        dragGhost.style.zIndex = "34"
        root.appendChild(dragGhost)

        dropIndicator = document.createElement("div")
        dropIndicator.setAttribute("class", "gantt-tree-row-drop-indicator")
        leftPanel.appendChild(dropIndicator)

        hideDragGhost = ->
            dragGhost.classList.remove("is-visible")
            dragGhost.style.display = "none"
            dragGhost.style.left = "-9999px"
            dragGhost.style.top = "-9999px"

        hideDropIndicator = ->
            dropIndicator.classList.remove("is-visible")

        isTreeReorderEnabled = ->
            ctrl = $scope.ctrl
            return false if !ctrl?
            return false if ctrl.barsLocked
            return false if ctrl.barHistoryBusy
            return false if ctrl.treeRowReorderBusy
            return false if ctrl.colorPickerModeActive
            return false if ctrl.barLinkModeActive
            return true

        getClosestTreeRow = (target) ->
            node = target

            while node? and node != leftPanel
                if node.classList?.contains("gantt-tree-row")
                    rowId = node.getAttribute?("data-gantt-row-id")
                    return node if rowId?

                node = node.parentNode

            return null

        getRowHandle = (row) ->
            return null if !row?
            return row.querySelector(HANDLE_SELECTOR)

        findHandleFromTarget = (target, row) ->
            return null if !target? or !row?

            node = target
            while node? and node != row and node != leftPanel
                return node if node.classList?.contains("gantt-tree-reorder-handle")
                node = node.parentNode

            if node == row
                return node if node.classList?.contains("gantt-tree-reorder-handle")
            return null

        findChevronFromRow = (row) ->
            return null if !row?
            return row.querySelector(".gantt-row-toggle .gantt-chevron")

        isEventOnReorderHandle = (event, row = null) ->
            return false if !event?
            row = getClosestTreeRow(event.target) if !row?
            return false if !row?

            rowHandle = getRowHandle(row)
            return false if !rowHandle? or !rowHandle.offsetParent?
            return !!findHandleFromTarget(event.target, row)

        isBeforeChevronToggleArea = (event, row) ->
            return false if !event? or !row?
            return false if !row.classList?.contains("is-collapsible")

            chevron = findChevronFromRow(row)
            return false if !chevron?

            chevronRect = chevron.getBoundingClientRect()
            return false if !chevronRect? or chevronRect.width <= 0

            return event.clientX < chevronRect.left

        setHandleHoverState = (isActive) ->
            leftPanel.classList.toggle(HANDLE_HOVER_CLASS, !!isActive)

        getRowElementById = (rowId) ->
            return null if !rowId?
            return leftPanel.querySelector(".gantt-tree-row[data-gantt-row-id=\"#{rowId}\"]")

        updateDragGhostPosition = (clientX, clientY) ->
            dragGhost.style.left = "#{Math.round(clientX - DRAG_GHOST_POINTER_INSET_X)}px"
            dragGhost.style.top = "#{Math.round(clientY - DRAG_GHOST_POINTER_INSET_Y)}px"

        resolveDropTarget = (clientY) ->
            return null if !active?

            siblingRows = _.compact(_.map(active.siblingRowIds or [], (rowId) ->
                return getRowElementById(rowId)
            ))
            visibleSiblingRows = _.filter(siblingRows, (row) ->
                return row.offsetParent?
            )
            return null if !visibleSiblingRows.length

            referenceRows = _.filter(visibleSiblingRows, (row) ->
                return row.getAttribute("data-gantt-row-id") != active.rowId
            )
            return null if !referenceRows.length

            rowMetrics = _.map(referenceRows, (row) ->
                rect = row.getBoundingClientRect()
                return {
                    row: row
                    top: rect.top
                    bottom: rect.bottom
                    mid: rect.top + (rect.height / 2)
                }
            )

            insertIndex = rowMetrics.length
            if clientY < rowMetrics[0].mid
                insertIndex = 0
            else if clientY >= rowMetrics[rowMetrics.length - 1].mid
                insertIndex = rowMetrics.length
            else
                for metric, index in rowMetrics
                    continue if index == 0

                    previousMetric = rowMetrics[index - 1]
                    if clientY >= previousMetric.mid and clientY < metric.mid
                        insertIndex = index
                        break

            lineTopClient = if insertIndex >= rowMetrics.length
                rowMetrics[rowMetrics.length - 1].bottom
            else
                rowMetrics[insertIndex].top

            panelRect = leftPanel.getBoundingClientRect()
            lineTop = lineTopClient - panelRect.top + leftPanel.scrollTop

            return {
                targetIndex: insertIndex
                lineTop: lineTop
            }

        updateDropIndicator = (clientY) ->
            target = resolveDropTarget(clientY)

            if !target?
                active.targetIndex = null if active?
                hideDropIndicator()
                return

            if _.isNumber(active?.currentIndex) and target.targetIndex == active.currentIndex
                active.targetIndex = null if active?
                hideDropIndicator()
                return

            active.targetIndex = target.targetIndex if active?

            dropIndicator.style.top = "#{Math.round(target.lineTop)}px"
            dropIndicator.style.left = "0px"
            dropIndicator.style.width = "#{Math.max(leftPanel.scrollWidth, leftPanel.clientWidth)}px"
            dropIndicator.classList.add("is-visible")

        stopTreeRowDrag = ->
            return if !active?

            finishedDrag = active
            active = null

            $document.off("mousemove", onTreeRowDragMouseMove)
            $document.off("mouseup", onTreeRowDragMouseUp)
            root.classList.remove(DRAG_CLASS)
            setHandleHoverState(false)
            hideDragGhost()
            hideDropIndicator()

            return if !_.isNumber(finishedDrag.targetIndex)

            $scope.ctrl?.requestGanttRowReorder?(finishedDrag.rowId, finishedDrag.targetIndex)

        startTreeRowDrag = (event, row) ->
            rowId = row.getAttribute("data-gantt-row-id")
            return false if !rowId?

            context = $scope.ctrl?.getGanttRowReorderContext?(rowId)
            return false if !context? or !_.isArray(context.siblingRowIds)
            return false if context.siblingRowIds.length < 2

            active = {
                rowId: rowId
                siblingRowIds: context.siblingRowIds.slice(0)
                currentIndex: context.rowIndex
                targetIndex: null
            }

            rowRect = row.getBoundingClientRect()
            dragGhost.style.width = "#{Math.round(rowRect.width)}px"
            dragGhost.style.height = "#{Math.round(rowRect.height)}px"
            dragGhost.style.display = "block"
            updateDragGhostPosition(event.clientX, event.clientY)
            dragGhost.classList.add("is-visible")
            root.classList.add(DRAG_CLASS)
            setHandleHoverState(false)
            updateDropIndicator(event.clientY)

            $document.on("mousemove", onTreeRowDragMouseMove)
            $document.on("mouseup", onTreeRowDragMouseUp)
            return true

        onTreeRowHoverMouseMove = (event) ->
            return if active?

            if !isTreeReorderEnabled()
                setHandleHoverState(false)
                return

            row = getClosestTreeRow(event.target)
            if !row?
                setHandleHoverState(false)
                return

            setHandleHoverState(isEventOnReorderHandle(event, row))

        onTreeRowMouseDown = (event) ->
            return if event.button? and event.button != 0
            return if active?
            return if !isTreeReorderEnabled()

            row = getClosestTreeRow(event.target)
            return if !row?
            return if !isEventOnReorderHandle(event, row)
            return if !startTreeRowDrag(event, row)

            event.preventDefault()
            event.stopPropagation()

        onTreeRowClick = (event) ->
            row = getClosestTreeRow(event.target)
            return if !row?

            if isEventOnReorderHandle(event, row)
                event.preventDefault()
                event.stopPropagation()
                return

            return if !isBeforeChevronToggleArea(event, row)
            event.preventDefault()
            event.stopPropagation()

        onTreeRowMouseLeave = ->
            return if active?
            setHandleHoverState(false)

        onTreeRowDragMouseMove = (event) ->
            return if !active?
            updateDragGhostPosition(event.clientX, event.clientY)
            updateDropIndicator(event.clientY)
            event.preventDefault()

        onTreeRowDragMouseUp = (event) ->
            return if !active?
            event.preventDefault()
            stopTreeRowDrag()

        unwatchBarsLock = $scope.$watch("ctrl.barsLocked", (locked) ->
            if locked
                stopTreeRowDrag()
                setHandleHoverState(false)
        )

        leftPanel.addEventListener("mousemove", onTreeRowHoverMouseMove)
        leftPanel.addEventListener("mousedown", onTreeRowMouseDown)
        leftPanel.addEventListener("click", onTreeRowClick, true)
        leftPanel.addEventListener("mouseleave", onTreeRowMouseLeave)

        $scope.$on "$destroy", ->
            leftPanel.removeEventListener("mousemove", onTreeRowHoverMouseMove)
            leftPanel.removeEventListener("mousedown", onTreeRowMouseDown)
            leftPanel.removeEventListener("click", onTreeRowClick, true)
            leftPanel.removeEventListener("mouseleave", onTreeRowMouseLeave)
            stopTreeRowDrag()
            setHandleHoverState(false)
            dropIndicator.remove()
            dragGhost.remove()
            unwatchBarsLock?()

    return {link: link}

module.directive("tgGanttTreeReorder", ["$document", GanttTreeReorderDirective])

GanttBarResizeDirective = ($document) ->
    link = ($scope, $el) ->
        root = $el[0]
        leftPanel = root.querySelector(".gantt-left-panel")
        rightPanel = root.querySelector(".gantt-right-panel")
        return if !leftPanel? or !rightPanel?

        active = null
        DRAG_CLASS = "is-resizing-gantt-bar"
        MOVE_DRAG_CLASS = "is-moving-gantt-bar"
        CREATE_DRAG_CLASS = "is-creating-gantt-bar"
        HOVER_CLASS = "is-hovering-gantt-edge"
        LINK_DRAG_CLASS = "is-dragging-gantt-link"
        LINK_DRAG_MOVE_THRESHOLD_PX = 3
        SVG_NS = "http://www.w3.org/2000/svg"
        INDICATOR_FRAME_WIDTH = 10
        INDICATOR_ARROW_WIDTH = 6
        INDICATOR_WIDTH = INDICATOR_FRAME_WIDTH + INDICATOR_ARROW_WIDTH
        INDICATOR_GAP_PX = 1
        INDICATOR_PAD_Y_PX = 4
        activeLinkDrag = null
        linkDragPreviewPath = null
        linkDragPreviewArrowhead = null
        visibleLinkSourceCapsRowId = null
        hoverSourceCapLayer = null
        hoverSourceCapPathsBySourceRowId = {}
        hoveredBar = null
        hoveredEdge = null
        linkHoveredBar = null
        edgeIndicator = document.createElementNS(SVG_NS, "svg")
        edgeIndicator.setAttribute("class", "gantt-edge-indicator")
        edgeIndicator.style.width = "0"
        edgeIndicator.style.height = "0"
        edgeIndicator.setAttribute("width", 0)
        edgeIndicator.setAttribute("height", 0)
        edgeIndicatorLine = document.createElementNS(SVG_NS, "path")
        edgeIndicatorLine.classList.add("gantt-edge-indicator-line")
        edgeIndicatorArrow = document.createElementNS(SVG_NS, "path")
        edgeIndicatorArrow.classList.add("gantt-edge-indicator-arrow")
        edgeIndicator.appendChild(edgeIndicatorLine)
        edgeIndicator.appendChild(edgeIndicatorArrow)
        rightPanel.appendChild(edgeIndicator)
        limitIndicator = document.createElement("div")
        limitIndicator.setAttribute("class", "gantt-resize-limit-indicator")
        rightPanel.appendChild(limitIndicator)
        moveEndLimitIndicator = document.createElement("div")
        moveEndLimitIndicator.setAttribute("class", "gantt-resize-limit-indicator")
        rightPanel.appendChild(moveEndLimitIndicator)
        resizePopup = document.createElement("div")
        resizePopup.setAttribute("class", "gantt-bar-resize-popup")
        resizePopupStart = document.createElement("div")
        resizePopupStart.setAttribute("class", "gantt-bar-resize-popup-line")
        resizePopupEnd = document.createElement("div")
        resizePopupEnd.setAttribute("class", "gantt-bar-resize-popup-line")
        resizePopup.appendChild(resizePopupStart)
        resizePopup.appendChild(resizePopupEnd)
        rightPanel.appendChild(resizePopup)

        getSvgForBar = (bar) ->
            node = bar
            while node?
                return node if node.tagName?.toLowerCase?() == "svg"
                node = node.parentNode
            return null

        getBarsSvg = ->
            return rightPanel.querySelector(".gantt-bars-svg")

        ensureHoverSourceCapLayer = (svg = null) ->
            targetSvg = svg or getBarsSvg()
            return null if !targetSvg?

            linkLayer = targetSvg.querySelector(".gantt-link-layer") or targetSvg
            if !hoverSourceCapLayer? or hoverSourceCapLayer.parentNode != linkLayer
                hoverSourceCapLayer?.remove()
                hoverSourceCapLayer = document.createElementNS(SVG_NS, "g")
                hoverSourceCapLayer.setAttribute("class", "gantt-link-hover-source-cap-layer")
                linkLayer.appendChild(hoverSourceCapLayer)
                hoverSourceCapPathsBySourceRowId = {}

            return hoverSourceCapLayer

        clearHoverSourceCaps = ->
            _.each(hoverSourceCapPathsBySourceRowId, (sourceCapPath) ->
                sourceCapPath?.remove()
            )
            hoverSourceCapPathsBySourceRowId = {}

        getSvgRowCount = (svg) ->
            viewBoxRaw = (svg?.getAttribute("viewBox") or "").trim()
            viewBoxParts = if viewBoxRaw.length then viewBoxRaw.split(/\s+/) else []

            if viewBoxParts.length >= 4
                parsedRowCount = parseFloat(viewBoxParts[3])
                return parsedRowCount if isFinite(parsedRowCount) and parsedRowCount > 0

            fallbackRowCount = parseFloat($scope.ctrl?.timeline?.rowCount or "1")
            fallbackRowCount = 1 if !isFinite(fallbackRowCount) or fallbackRowCount <= 0
            return fallbackRowCount

        getTimelineGrid = ->
            return rightPanel.querySelector(".gantt-timeline-grid")

        getVisibleRows = ->
            rows = Array.from(leftPanel.querySelectorAll(".gantt-tree-row"))
            return rows.filter((row) -> row.offsetParent?)

        getBarDetailUnits = (baseUnits) ->
            baseSlotWidthRem = parseFloat($scope.ctrl?.dayWidthRem or "2.2")
            baseSlotWidthRem = 2.2 if isNaN(baseSlotWidthRem) or baseSlotWidthRem <= 0

            slotWidthRem = parseFloat($scope.ctrl?.timeline?.slotWidthRem or "#{baseSlotWidthRem}")
            slotWidthRem = baseSlotWidthRem if isNaN(slotWidthRem) or slotWidthRem <= 0

            return baseUnits * (baseSlotWidthRem / slotWidthRem)

        buildEpicPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            tip = rowIndex + 0.74
            span = Math.max(right - left, 0.5)
            inset = Math.min(getBarDetailUnits(0.28), span / 3)
            xRadius = Math.min(getBarDetailUnits(0.25), span / 3)
            yRadius = Math.min(.17, (bottom - top) / 2)
            "M#{left},#{top + yRadius}Q#{left},#{top} #{left + xRadius},#{top}L#{right - xRadius},#{top}Q#{right},#{top} #{right},#{top + yRadius}L#{right},#{bottom}L#{right},#{tip}L#{right - inset},#{bottom}L#{left + inset},#{bottom}L#{left},#{tip}L#{left},#{bottom}z"

        buildStoryPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            span = Math.max(right - left, 0.5)
            yRadius = (bottom - top) / 2
            xRadius = Math.min(getBarDetailUnits(0.18), span / 2)
            innerLeft = left + xRadius
            innerRight = right - xRadius
            "M#{innerLeft},#{top}L#{innerRight},#{top}A#{xRadius},#{yRadius} 0 0 1 #{innerRight},#{bottom}L#{innerLeft},#{bottom}A#{xRadius},#{yRadius} 0 0 1 #{innerLeft},#{top}z"

        buildRoundedRect = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            width = Math.max(right - left, .35)
            rx = Math.min(getBarDetailUnits(0.16), width / 2)
            {
                x: left
                y: rowIndex + 0.28
                width: width
                height: 0.50
                rx: rx
                ry: 0.16
            }

        getVisibleRowIndex = (rowId) ->
            visibleRows = getVisibleRows()
            index = _.findIndex(visibleRows, (row) ->
                row.getAttribute("data-gantt-row-id") == rowId
            )
            if index < 0 then 0 else index

        renderBarGeometry = (bar, startDay, endDay, rowIndex, totalDays) ->
            shape = bar.getAttribute("data-shape") or "arrow"
            barType = bar.getAttribute("data-bar-type") or ""

            if shape == "rounded"
                rounded = buildRoundedRect(startDay, endDay, rowIndex, totalDays)
                bar.setAttribute("x", rounded.x)
                bar.setAttribute("y", rounded.y)
                bar.setAttribute("width", rounded.width)
                bar.setAttribute("height", rounded.height)
                bar.setAttribute("rx", rounded.rx)
                bar.setAttribute("ry", rounded.ry)
            else
                path = if barType == "story" then buildStoryPath(startDay, endDay, rowIndex, totalDays) else buildEpicPath(startDay, endDay, rowIndex, totalDays)
                bar.setAttribute("d", path)

        createPreviewBar = (svg, rowId, row, startDay, endDay, rowIndex, totalDays) ->
            barType = row?.type or "task"
            shape = if barType == "task" then "rounded" else "arrow"
            tagName = if shape == "rounded" then "rect" else "path"
            bar = document.createElementNS(SVG_NS, tagName)
            bar.setAttribute("class", "gantt-bar gantt-bar-#{barType} gantt-bar-create-preview")
            bar.setAttribute("data-gantt-row-id", rowId)
            bar.setAttribute("data-bar-type", barType)
            bar.setAttribute("data-shape", shape)
            bar.setAttribute("data-can-edit", "true")
            bar.setAttribute("data-start-day", startDay)
            bar.setAttribute("data-end-day", endDay)
            bar.setAttribute("data-row-index", rowIndex)
            if shape != "rounded"
                shapeRendering = if barType == "epic" then "geometricPrecision" else "crispEdges"
                bar.setAttribute("shape-rendering", shapeRendering)
            bar.style.fill = row.barColor if row?.barColor?

            renderBarGeometry(bar, startDay, endDay, rowIndex, totalDays)
            svg.appendChild(bar)
            return bar

        getNearestBarElement = (target) ->
            node = target
            while node? and node != rightPanel
                return node if node.classList?.contains("gantt-bar")
                node = node.parentNode
            return null

        resolveResizeEdge = (bar, event) ->
            rect = bar.getBoundingClientRect()
            return null if rect.width <= 0

            handleZonePx = Math.min(14, Math.max(8, rect.width * 0.22))
            return "start" if event.clientX - rect.left <= handleZonePx
            return "end" if rect.right - event.clientX <= handleZonePx
            return null

        clamp = (value, minValue, maxValue) ->
            Math.max(minValue, Math.min(value, maxValue))

        getEventTimelinePosition = (event, svg, totalDays) ->
            rect = svg?.getBoundingClientRect()
            return 0 if !rect? or rect.width <= 0

            relativeX = event.clientX - rect.left
            position = (relativeX / rect.width) * totalDays
            return clamp(position, 0, totalDays)

        getSlotIndexForEvent = (event, svg, totalDays) ->
            position = getEventTimelinePosition(event, svg, totalDays)
            slotIndex = Math.floor(position) + 1
            return clamp(slotIndex, 1, totalDays)

        getEventTimelineYPosition = (event, svg, rowCount) ->
            rect = svg?.getBoundingClientRect()
            return 0 if !rect? or rect.height <= 0

            relativeY = event.clientY - rect.top
            position = (relativeY / rect.height) * rowCount
            return clamp(position, 0, rowCount)

        getBarLinkAnchorPoint = (bar, totalDays) ->
            startDay = parseFloat(bar?.getAttribute("data-start-day") or "1")
            endDay = parseFloat(bar?.getAttribute("data-end-day") or "#{startDay}")
            rowIndex = parseFloat(bar?.getAttribute("data-row-index") or "0")

            startDay = 1 if !isFinite(startDay) or startDay <= 0
            endDay = startDay if !isFinite(endDay) or endDay < startDay
            rowIndex = 0 if !isFinite(rowIndex)

            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)

            return {
                x: (left + right) / 2
                y: rowIndex + 0.5
            }

        isEventInsideTimelineGrid = (event) ->
            grid = getTimelineGrid()
            return false if !grid?

            node = event.target
            while node? and node != rightPanel
                return true if node == grid
                node = node.parentNode

            return false

        getGridRowForEvent = (event) ->
            grid = getTimelineGrid()
            return null if !grid?

            gridRect = grid.getBoundingClientRect()
            return null if gridRect.height <= 0
            return null if event.clientY < gridRect.top or event.clientY > gridRect.bottom

            visibleRows = getVisibleRows()
            return null if !visibleRows.length

            rowHeight = gridRect.height / visibleRows.length
            return null if rowHeight <= 0

            rowIndex = Math.floor((event.clientY - gridRect.top) / rowHeight)
            rowIndex = clamp(rowIndex, 0, visibleRows.length - 1)
            row = visibleRows[rowIndex]
            rowId = row?.getAttribute("data-gantt-row-id")
            return null if !rowId?

            return {
                rowId: rowId
                rowIndex: rowIndex
            }

        isBarEditable = (bar) ->
            return false if !bar?
            return bar.getAttribute("data-can-edit") == "true"

        isBarInteractionLocked = ->
            ctrl = $scope.ctrl
            return false if !ctrl?
            return true if ctrl.barHistoryBusy
            return ctrl.isBarEditingLocked() if _.isFunction(ctrl.isBarEditingLocked)
            return !!ctrl.barsLocked

        isBarLinkModeActive = ->
            return !!$scope.ctrl?.barLinkModeActive

        getBarModel = (rowId) ->
            return null if !rowId?

            return _.find($scope.ctrl?.ganttBars or [], (barModel) ->
                return barModel?.rowId == rowId
            )

        getRowModel = (rowId) ->
            return null if !rowId?
            return $scope.ctrl?.rowNodesById?[rowId]

        canCreateBarForRow = (rowId) ->
            ctrl = $scope.ctrl
            return false if !ctrl?.canCreateBarDateRange?
            return ctrl.canCreateBarDateRange(rowId)

        getResizeLimitsForRow = (rowId) ->
            barModel = getBarModel(rowId)
            limits = barModel?.resizeLimits
            if !limits? and $scope.ctrl?.getGanttRowResizeLimits?
                limits = $scope.ctrl.getGanttRowResizeLimits(rowId)
            return limits

        buildResizeLimit = (limits, edge) ->
            return null if !limits?

            edgeLimit = limits[edge]
            return null if !edgeLimit?.position?

            return {
                key: edge
                position: edgeLimit.position
                slotIndex: edgeLimit.slotIndex
                relatedRowIds: edgeLimit.relatedRowIds or limits.descendantRowIds or []
            }

        getResizeLimitForRow = (rowId, edge) ->
            return buildResizeLimit(getResizeLimitsForRow(rowId), edge)

        getResizeLimit = (bar, edge) ->
            rowId = bar?.getAttribute("data-gantt-row-id")
            return getResizeLimitForRow(rowId, edge)

        getMoveLeftLimit = (bar, baseStartDay = null, baseEndDay = null) ->
            endLimit = getResizeLimit(bar, "end")
            dependencyStartLimit = getResizeLimit(bar, "dependencyStart")

            return null if !endLimit? and !dependencyStartLimit?
            return dependencyStartLimit if !endLimit?
            return endLimit if !dependencyStartLimit?

            startDay = parseInt(baseStartDay, 10)
            if isNaN(startDay)
                startDay = parseInt(bar?.getAttribute("data-start-day") or "1", 10)
            startDay = Math.max(1, startDay)

            endDay = parseInt(baseEndDay, 10)
            if isNaN(endDay)
                endDay = parseInt(bar?.getAttribute("data-end-day") or "#{startDay}", 10)
            endDay = Math.max(startDay, endDay)

            endLimitDelta = endLimit.slotIndex - endDay
            dependencyStartDelta = dependencyStartLimit.slotIndex - startDay

            return dependencyStartLimit if dependencyStartDelta >= endLimitDelta
            return endLimit

        getBarFillColor = (bar) ->
            return "" if !bar?

            computed = window.getComputedStyle(bar)
            fill = computed?.fill
            return fill if fill? and fill != "none" and fill != "rgba(0, 0, 0, 0)"

            return bar.getAttribute("fill") or ""

        findBarByRowId = (rowId) ->
            return null if !rowId?

            bars = Array.from(root.querySelectorAll(".gantt-bar[data-gantt-row-id]:not(.gantt-bar-create-preview)"))
            return _.find(bars, (candidate) ->
                return candidate.getAttribute("data-gantt-row-id") == rowId
            )

        normalizeRowReferenceId = (value) ->
            return null if !value?

            if _.isObject(value)
                return normalizeRowReferenceId(value.id) if value.id?
                return null

            numericValue = parseInt(value, 10)
            return numericValue if !isNaN(numericValue)
            return "#{value}"

        getParentRowId = (rowId) ->
            row = getRowModel(rowId)
            return null if !row?

            if row.type == "task"
                storyId = normalizeRowReferenceId(row.item?.user_story) or normalizeRowReferenceId(row.item?.user_story_extra_info?.id)
                return "story-#{storyId}" if storyId?
                return null

            if row.type == "story"
                epicId = normalizeRowReferenceId(row.epicId)
                return "epic-#{epicId}" if epicId?
                return null

            return null

        isBarVisibleInTimeline = (bar) ->
            return false if !bar?
            return false if bar.classList.contains("is-hidden")
            return false if bar.getAttribute("data-sync-hidden") == "true"
            return false if bar.getAttribute("visibility") == "hidden"
            return true

        resolveVisibleSourceBar = (sourceRowId, barsByRowId = null) ->
            currentRowId = sourceRowId
            depth = 0

            while currentRowId?
                bar = if barsByRowId? then barsByRowId[currentRowId] else findBarByRowId(currentRowId)
                if isBarVisibleInTimeline(bar)
                    return {
                        rowId: currentRowId
                        bar: bar
                        depth: depth
                    }

                currentRowId = getParentRowId(currentRowId)
                depth += 1

            return null

        getSourceAnchorEndDay = (sourceRowId, fallbackBar = null) ->
            barModel = getBarModel(sourceRowId)
            endDay = parseFloat(barModel?.endDay)
            return endDay if isFinite(endDay) and endDay > 0

            fallbackEndDay = parseFloat(fallbackBar?.getAttribute("data-end-day") or "0")
            return fallbackEndDay if isFinite(fallbackEndDay) and fallbackEndDay > 0

            return null

        getBarBottomAnchorY = (bar, rowIndex) ->
            shape = bar?.getAttribute("data-shape") or ""
            barType = bar?.getAttribute("data-bar-type") or ""

            return rowIndex + 0.78 if shape == "rounded"
            return rowIndex + 0.64 if barType == "epic"
            return rowIndex + 0.64 if barType == "story"
            return rowIndex + 0.58

        getBarTopAnchorY = (bar, rowIndex) ->
            shape = bar?.getAttribute("data-shape") or ""
            barType = bar?.getAttribute("data-bar-type") or ""

            return rowIndex + 0.28 if shape == "rounded"
            return rowIndex + 0.17 if barType == "epic"
            return rowIndex + 0.16 if barType == "story"
            return rowIndex + 0.22

        buildTreeRowOrderById = ->
            orderById = {}
            nextIndex = 0

            walk = (node) ->
                return if !node?.rowId?
                orderById[node.rowId] = nextIndex
                nextIndex += 1
                _.each(node.children or [], (child) ->
                    walk(child)
                )

            _.each($scope.ctrl?.tree or [], (rootNode) ->
                walk(rootNode)
            )

            return orderById

        buildPromotedSourceStemPath = (sourceX, sourceY, depth) ->
            stemDepth = Math.max(1, depth)
            stemLength = 0.38 + ((stemDepth - 1) * 0.16)
            stemStartY = sourceY + stemLength
            return "M#{sourceX},#{stemStartY}L#{sourceX},#{sourceY}"

        setVisibleLinkSourceCapsForRow = (rowId = null, force = false) ->
            targetRowId = if rowId? then "#{rowId}" else null
            sourceCaps = Array.from(root.querySelectorAll(".gantt-link-source-cap[data-source-row-id]"))

            if !force and targetRowId? and visibleLinkSourceCapsRowId == targetRowId
                return

            visibleLinkSourceCapsRowId = targetRowId
            _.each(sourceCaps, (sourceCap) ->
                sourceCap.classList.remove("is-visible")
            )
            clearHoverSourceCaps()
            return if !targetRowId?

            svg = getBarsSvg()
            return if !svg?

            sourceCapLayer = ensureHoverSourceCapLayer(svg)
            return if !sourceCapLayer?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)
            rowCount = getSvgRowCount(svg)
            svgRect = svg.getBoundingClientRect()
            xScale = svgRect.width / totalDays
            yScale = svgRect.height / Math.max(1, rowCount)
            return if !isFinite(xScale) or xScale <= 0
            return if !isFinite(yScale) or yScale <= 0

            endpointGap = getBarDetailUnits(0.08)
            sourceCapHalfHeightY = 4 / yScale
            sourceCapHalfWidthX = 4 / xScale
            incomingSourceRowIds = {}
            rowOrderById = buildTreeRowOrderById()

            _.each($scope.ctrl?.barLinks or [], (link) ->
                sourceRowId = link?.sourceRowId
                targetRowIdForLink = link?.targetRowId
                return if !sourceRowId? or !targetRowIdForLink? or targetRowIdForLink != targetRowId
                incomingSourceRowIds["#{sourceRowId}"] = true
            )

            _.each(incomingSourceRowIds, (isIncoming, sourceRowId) ->
                return if !isIncoming

                sourceResolution = resolveVisibleSourceBar(sourceRowId)
                sourceBar = sourceResolution?.bar
                return if !sourceBar?

                sourceEndDay = getSourceAnchorEndDay(sourceRowId, sourceBar)
                sourceRowIndex = parseFloat(sourceBar.getAttribute("data-row-index") or "0")
                return if !isFinite(sourceEndDay) or !isFinite(sourceRowIndex)

                sourceX = Math.min(totalDays, sourceEndDay + endpointGap)
                sourceOrder = rowOrderById[sourceRowId]
                targetOrder = rowOrderById[targetRowId]
                isSourceBelowTarget = _.isNumber(sourceOrder) and _.isNumber(targetOrder) and sourceOrder > targetOrder
                sourceY = if sourceResolution.depth > 0
                    if isSourceBelowTarget then getBarTopAnchorY(sourceBar, sourceRowIndex) else getBarBottomAnchorY(sourceBar, sourceRowIndex)
                else
                    sourceRowIndex + 0.5

                hoverSourceCap = document.createElementNS(SVG_NS, "path")
                hoverSourceCap.setAttribute("class", "gantt-link-source-cap gantt-link-source-cap-hover is-visible")
                hoverSourceCap.setAttribute("data-source-row-id", sourceRowId)
                hoverSourceCap.setAttribute("data-target-row-id", targetRowId)
                hoverSourceCapPath = if sourceResolution.depth > 0
                    "M#{sourceX - sourceCapHalfWidthX},#{sourceY}L#{sourceX + sourceCapHalfWidthX},#{sourceY}"
                else
                    "M#{sourceX},#{sourceY - sourceCapHalfHeightY}L#{sourceX},#{sourceY + sourceCapHalfHeightY}"
                hoverSourceCap.setAttribute(
                    "d",
                    hoverSourceCapPath
                )
                sourceCapLayer.appendChild(hoverSourceCap)
                hoverSourceCapPathsBySourceRowId["#{sourceRowId}"] = hoverSourceCap
            )

        hideLimitIndicator = (indicator) ->
            indicator?.classList?.remove("is-visible")

        clearLimitIndicator = ->
            hideLimitIndicator(limitIndicator)
            hideLimitIndicator(moveEndLimitIndicator)

        clearResizePopup = ->
            resizePopup.classList.remove("is-visible")

        formatResizePopupDate = (slotIndex) ->
            timelineStart = $scope.ctrl?.timeline?.start
            return "-" if !timelineStart?

            normalizedSlot = parseInt(slotIndex, 10)
            normalizedSlot = 1 if isNaN(normalizedSlot)
            normalizedSlot = Math.max(1, normalizedSlot)

            dateFormat = translateResizePopupText("PROJECT.GANTT.RESIZE_POPUP.DATE_FORMAT", "DD MMMM YYYY")
            return timelineStart.clone().add(normalizedSlot - 1, "day").format(dateFormat)

        translateResizePopupText = (key, fallback) ->
            translator = $scope.ctrl?.translate
            translated = if translator?.instant? then translator.instant(key) else null

            return fallback if !translated? or translated == key
            return translated

        positionResizePopup = (bar, startDay, endDay, edge) ->
            return clearResizePopup() if !bar?

            panelRect = rightPanel.getBoundingClientRect()
            barRect = bar.getBoundingClientRect()
            return clearResizePopup() if barRect.width <= 0 or barRect.height <= 0

            startLabel = translateResizePopupText("PROJECT.GANTT.RESIZE_POPUP.START", "Start")
            endLabel = translateResizePopupText("PROJECT.GANTT.RESIZE_POPUP.END", "End")
            resizePopupStart.textContent = "#{startLabel}: #{formatResizePopupDate(startDay)}"
            resizePopupEnd.textContent = "#{endLabel}: #{formatResizePopupDate(endDay)}"
            resizePopup.classList.add("is-visible")

            popupWidth = resizePopup.offsetWidth or 0
            popupHeight = resizePopup.offsetHeight or 0
            edgeX = if edge == "start" then barRect.left else barRect.right
            left = edgeX - panelRect.left + rightPanel.scrollLeft + 10
            maxLeft = rightPanel.scrollLeft + rightPanel.clientWidth - popupWidth - 8
            left = Math.max(rightPanel.scrollLeft + 8, Math.min(left, maxLeft))

            top = barRect.top - panelRect.top + rightPanel.scrollTop - popupHeight - 8
            if top < rightPanel.scrollTop + 8
                top = barRect.bottom - panelRect.top + rightPanel.scrollTop + 8

            resizePopup.style.left = "#{Math.round(left)}px"
            resizePopup.style.top = "#{Math.round(top)}px"

        positionLimitIndicator = (bar, edgeOrLimit, indicator = limitIndicator) ->
            limit = if _.isString(edgeOrLimit) then getResizeLimit(bar, edgeOrLimit) else edgeOrLimit
            return hideLimitIndicator(indicator) if !limit?

            svg = getSvgForBar(bar)
            return hideLimitIndicator(indicator) if !svg?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)

            svgRect = svg.getBoundingClientRect()
            panelRect = rightPanel.getBoundingClientRect()
            barRect = bar.getBoundingClientRect()
            return hideLimitIndicator(indicator) if svgRect.width <= 0 or barRect.height <= 0

            x = svgRect.left - panelRect.left
            x += rightPanel.scrollLeft
            x += (limit.position / totalDays) * svgRect.width

            top = barRect.top - panelRect.top + rightPanel.scrollTop
            bottom = barRect.bottom - panelRect.top + rightPanel.scrollTop

            _.each(limit.relatedRowIds or [], (relatedRowId) ->
                relatedBar = findBarByRowId(relatedRowId)
                return if !relatedBar? or relatedBar.classList.contains("is-hidden")

                relatedRect = relatedBar.getBoundingClientRect()
                relatedTop = relatedRect.top - panelRect.top + rightPanel.scrollTop
                relatedBottom = relatedRect.bottom - panelRect.top + rightPanel.scrollTop
                top = Math.min(top, relatedTop)
                bottom = Math.max(bottom, relatedBottom)
            )

            indicator.style.left = "#{Math.round(x)}px"
            indicator.style.top = "#{Math.round(top)}px"
            indicator.style.height = "#{Math.max(1, Math.round(bottom - top))}px"
            indicator.style.backgroundColor = getBarFillColor(bar)
            indicator.classList.add("is-visible")

        positionStartLimitIndicators = (bar) ->
            positionLimitIndicator(bar, "start", limitIndicator)
            positionLimitIndicator(bar, "dependencyStart", moveEndLimitIndicator)

        positionMoveLimitIndicators = (bar, moveState = null) ->
            positionLimitIndicator(bar, "start", limitIndicator)
            leftLimit = getMoveLeftLimit(bar, moveState?.initialStartDay, moveState?.initialEndDay)
            positionLimitIndicator(bar, leftLimit, moveEndLimitIndicator)

        clearHover = ->
            if hoveredBar?
                hoveredBar.classList.remove("is-resize-edge")
                hoveredBar.classList.remove("is-resize-start")
                hoveredBar.classList.remove("is-resize-end")
                hoveredBar.classList.remove("is-move-bar")

            hoveredBar = null
            hoveredEdge = null
            rightPanel.classList.remove(HOVER_CLASS)
            edgeIndicator.classList.remove("is-visible")
            edgeIndicator.classList.remove("is-start")
            edgeIndicator.classList.remove("is-end")
            clearLimitIndicator()

        clearLinkHover = ->
            linkHoveredBar?.classList?.remove("is-link-target")
            linkHoveredBar = null

        setLinkHover = (bar) ->
            return if linkHoveredBar == bar
            clearHover()
            clearLinkHover()
            return if !bar?

            linkHoveredBar = bar
            linkHoveredBar.classList.add("is-link-target")
            setVisibleLinkSourceCapsForRow(linkHoveredBar.getAttribute("data-gantt-row-id"))

        buildIndicatorLinePath = (height, edge) ->
            top = 1
            bottom = Math.max(top + 2, height - 1)
            mid = (top + bottom) / 2
            baseX = if edge == "start" then INDICATOR_FRAME_WIDTH else 1
            segments = ["M#{baseX},#{top}L#{baseX},#{bottom}"]
            connectorX = if edge == "start" then baseX - 3 else baseX + 3
            segments.push("M#{baseX},#{mid}L#{connectorX},#{mid}")
            segments.join("")

        buildIndicatorArrowPath = (height, edge) ->
            top = 1
            bottom = Math.max(top + 2, height - 1)
            mid = (top + bottom) / 2
            arrowHalfHeight = 3
            if edge == "start"
                tipX = .5
                baseX = 4.5
                return "M#{tipX},#{mid}L#{baseX},#{mid - arrowHalfHeight}L#{baseX},#{mid + arrowHalfHeight}z"

            tipX = INDICATOR_WIDTH - .5
            baseX = INDICATOR_WIDTH - 4.5
            "M#{tipX},#{mid}L#{baseX},#{mid - arrowHalfHeight}L#{baseX},#{mid + arrowHalfHeight}z"

        buildLinkPreviewArrowheadPath = (tipX, tipY, direction, xScale, yScale) ->
            arrowHeadBackX = 5 / xScale
            arrowHalfHeightY = 5 / yScale
            arrowHeadBackY = 5 / yScale
            arrowHalfWidthX = 5 / xScale

            if direction == "down" or direction == "up"
                verticalDirection = if direction == "down" then 1 else -1
                headBaseY = tipY - (verticalDirection * arrowHeadBackY)
                return "M#{tipX - arrowHalfWidthX},#{headBaseY}L#{tipX},#{tipY}L#{tipX + arrowHalfWidthX},#{headBaseY}"

            horizontalDirection = if direction == "left" or direction == -1 then -1 else 1
            headBaseX = tipX - (horizontalDirection * arrowHeadBackX)
            return "M#{headBaseX},#{tipY - arrowHalfHeightY}L#{tipX},#{tipY}L#{headBaseX},#{tipY + arrowHalfHeightY}"

        ensureLinkDragPreviewElements = (svg) ->
            return if !svg?

            linkLayer = svg.querySelector(".gantt-link-layer") or svg
            currentParentMatches = linkDragPreviewPath?.parentNode == linkLayer and linkDragPreviewArrowhead?.parentNode == linkLayer
            return if currentParentMatches

            linkDragPreviewPath?.remove()
            linkDragPreviewArrowhead?.remove()

            linkDragPreviewPath = document.createElementNS(SVG_NS, "path")
            linkDragPreviewPath.setAttribute("class", "gantt-link-path gantt-link-preview is-hidden")

            linkDragPreviewArrowhead = document.createElementNS(SVG_NS, "path")
            linkDragPreviewArrowhead.setAttribute("class", "gantt-link-arrowhead gantt-link-preview is-hidden")

            linkLayer.appendChild(linkDragPreviewPath)
            linkLayer.appendChild(linkDragPreviewArrowhead)

        hideLinkDragPreview = ->
            linkDragPreviewPath?.classList?.add("is-hidden")
            linkDragPreviewArrowhead?.classList?.add("is-hidden")

        updateLinkDragPreview = (event) ->
            return if !activeLinkDrag?

            svg = activeLinkDrag.svg
            return hideLinkDragPreview() if !svg?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)
            rowCount = getSvgRowCount(svg)

            svgRect = svg.getBoundingClientRect()
            xScale = svgRect.width / totalDays
            yScale = svgRect.height / Math.max(1, rowCount)
            return hideLinkDragPreview() if svgRect.width <= 0 or svgRect.height <= 0
            return hideLinkDragPreview() if !isFinite(xScale) or xScale <= 0 or !isFinite(yScale) or yScale <= 0

            anchor = getBarLinkAnchorPoint(activeLinkDrag.sourceBar, totalDays)
            targetX = getEventTimelinePosition(event, svg, totalDays)
            targetY = getEventTimelineYPosition(event, svg, rowCount)
            return hideLinkDragPreview() if !isFinite(anchor?.x) or !isFinite(anchor?.y) or !isFinite(targetX) or !isFinite(targetY)

            deltaX = targetX - anchor.x
            deltaY = targetY - anchor.y
            direction = null

            if Math.abs(deltaX) >= Math.abs(deltaY)
                direction = if deltaX >= 0 then 1 else -1
            else
                direction = if deltaY >= 0 then "down" else "up"

            linkDragPreviewPath.setAttribute("d", "M#{anchor.x},#{anchor.y}L#{targetX},#{targetY}")
            linkDragPreviewArrowhead.setAttribute("d", buildLinkPreviewArrowheadPath(targetX, targetY, direction, xScale, yScale))
            linkDragPreviewPath.classList.remove("is-hidden")
            linkDragPreviewArrowhead.classList.remove("is-hidden")

        onLinkDragMouseMove = (event) ->
            return if !activeLinkDrag?

            movedX = Math.abs(event.clientX - activeLinkDrag.startX)
            movedY = Math.abs(event.clientY - activeLinkDrag.startY)
            activeLinkDrag.moved = true if movedX > LINK_DRAG_MOVE_THRESHOLD_PX or movedY > LINK_DRAG_MOVE_THRESHOLD_PX

            bar = getNearestBarElement(event.target)
            isValidTarget = bar? and bar != activeLinkDrag.sourceBar and !bar.classList.contains("is-hidden")

            if isValidTarget
                setLinkHover(bar)
            else
                clearLinkHover()

            updateLinkDragPreview(event)

        stopLinkDrag = (event = null, options = {}) ->
            return if !activeLinkDrag?

            finishedLinkDrag = activeLinkDrag
            activeLinkDrag = null
            $document.off("mousemove", onLinkDragMouseMove)
            $document.off("mouseup", stopLinkDrag)
            root.classList.remove(LINK_DRAG_CLASS)
            hideLinkDragPreview()

            finishedLinkDrag.sourceBar?.classList?.remove("is-link-source")
            clearLinkHover()
            clearHover()

            return if options.cancel == true

            sourceRowId = finishedLinkDrag.sourceRowId
            targetBar = if event? then getNearestBarElement(event.target) else null
            targetRowId = targetBar?.getAttribute("data-gantt-row-id")
            moved = finishedLinkDrag.moved

            if !moved and event?
                movedX = Math.abs(event.clientX - finishedLinkDrag.startX)
                movedY = Math.abs(event.clientY - finishedLinkDrag.startY)
                moved = movedX > LINK_DRAG_MOVE_THRESHOLD_PX or movedY > LINK_DRAG_MOVE_THRESHOLD_PX

            handled = false
            if targetRowId? and targetRowId != sourceRowId
                handled = !!$scope.ctrl?.toggleGanttBarLink?(sourceRowId, targetRowId)
            else if !moved
                handled = !!$scope.ctrl?.registerGanttBarLinkClick?(sourceRowId)

            $scope.$evalAsync() if handled

        startLinkDrag = (bar, event) ->
            return false if !bar?

            sourceRowId = bar.getAttribute("data-gantt-row-id")
            return false if !sourceRowId?

            svg = getBarsSvg()
            return false if !svg?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)
            rowCount = getSvgRowCount(svg)
            return false if rowCount <= 0

            stopLinkDrag(null, {cancel: true}) if activeLinkDrag?
            ensureLinkDragPreviewElements(svg)
            hideLinkDragPreview()

            activeLinkDrag = {
                sourceBar: bar
                sourceRowId: sourceRowId
                svg: svg
                totalDays: totalDays
                rowCount: rowCount
                startX: event.clientX
                startY: event.clientY
                moved: false
            }

            bar.classList.add("is-link-source")
            root.classList.add(LINK_DRAG_CLASS)
            updateLinkDragPreview(event)
            $document.on("mousemove", onLinkDragMouseMove)
            $document.on("mouseup", stopLinkDrag)
            return true

        positionEdgeIndicator = (bar, edge) ->
            panelRect = rightPanel.getBoundingClientRect()
            barRect = bar.getBoundingClientRect()
            indicatorHeight = Math.max(10, Math.round(barRect.height + (INDICATOR_PAD_Y_PX * 2)))
            x = if edge == "start"
                (barRect.left - panelRect.left) - INDICATOR_GAP_PX - INDICATOR_WIDTH
            else
                (barRect.right - panelRect.left) + INDICATOR_GAP_PX
            y = barRect.top - panelRect.top
            x += rightPanel.scrollLeft
            y += rightPanel.scrollTop

            edgeIndicator.style.left = "#{Math.round(x)}px"
            edgeIndicator.style.top = "#{Math.round(y - INDICATOR_PAD_Y_PX)}px"
            edgeIndicator.style.width = "#{INDICATOR_WIDTH}px"
            edgeIndicator.style.height = "#{indicatorHeight}px"
            edgeIndicator.setAttribute("width", INDICATOR_WIDTH)
            edgeIndicator.setAttribute("height", indicatorHeight)
            edgeIndicator.setAttribute("viewBox", "0 0 #{INDICATOR_WIDTH} #{indicatorHeight}")
            edgeIndicatorLine.setAttribute("d", buildIndicatorLinePath(indicatorHeight, edge))
            edgeIndicatorArrow.setAttribute("d", buildIndicatorArrowPath(indicatorHeight, edge))
            edgeIndicator.classList.remove("is-start")
            edgeIndicator.classList.remove("is-end")
            edgeIndicator.classList.add(if edge == "start" then "is-start" else "is-end")
            edgeIndicator.classList.add("is-visible")

        setHover = (bar, edge) ->
            return if hoveredBar == bar and hoveredEdge == edge

            clearHover()
            return if !bar? or !edge?

            hoveredBar = bar
            hoveredEdge = edge
            setVisibleLinkSourceCapsForRow(hoveredBar.getAttribute("data-gantt-row-id"))

            if edge == "move"
                hoveredBar.classList.add("is-move-bar")
                positionMoveLimitIndicators(bar)
                return

            hoveredBar.classList.add("is-resize-edge")
            hoveredBar.classList.add(if edge == "start" then "is-resize-start" else "is-resize-end")
            rightPanel.classList.add(HOVER_CLASS)
            positionEdgeIndicator(bar, edge)
            if edge == "start"
                positionStartLimitIndicators(bar)
            else
                positionLimitIndicator(bar, edge)

        stopDrag = ->
            return if !active?

            finishedDrag = active
            active = null
            root.classList.remove(DRAG_CLASS)
            root.classList.remove(MOVE_DRAG_CLASS)
            root.classList.remove(CREATE_DRAG_CLASS)
            finishedDrag.bar?.classList?.remove("is-dragging")
            finishedDrag.bar?.classList?.remove("is-move-bar")
            $document.off("mousemove", onDragMouseMove)
            $document.off("mouseup", stopDrag)
            clearLimitIndicator()
            clearResizePopup()

            if finishedDrag.isCreating
                finishedDrag.bar?.remove()

                ctrl = $scope.ctrl
                return if !ctrl?.saveBarDateRange?

                ctrl.saveBarDateRange(finishedDrag.rowId, finishedDrag.startDay, finishedDrag.endDay).then =>
                    $scope.$evalAsync()
                    return
                , =>
                    return
                return

            if finishedDrag.bar?
                finishedDrag.bar.setAttribute("data-start-day", finishedDrag.startDay)
                finishedDrag.bar.setAttribute("data-end-day", finishedDrag.endDay)
                renderBarGeometry(
                    finishedDrag.bar,
                    finishedDrag.startDay,
                    finishedDrag.endDay,
                    finishedDrag.rowIndex,
                    finishedDrag.totalDays
                )

            changed = finishedDrag.startDay != finishedDrag.initialStartDay or finishedDrag.endDay != finishedDrag.initialEndDay
            return if !changed

            ctrl = $scope.ctrl
            return if !ctrl?.saveBarDateRange?

            ctrl.saveBarDateRange(finishedDrag.rowId, finishedDrag.startDay, finishedDrag.endDay).then =>
                $scope.$evalAsync()
                return
            , =>
                return if !finishedDrag?.bar?
                finishedDrag.bar.setAttribute("data-start-day", finishedDrag.initialStartDay)
                finishedDrag.bar.setAttribute("data-end-day", finishedDrag.initialEndDay)
                renderBarGeometry(
                    finishedDrag.bar,
                    finishedDrag.initialStartDay,
                    finishedDrag.initialEndDay,
                    finishedDrag.rowIndex,
                    finishedDrag.totalDays
                )
                return

        onDragMouseMove = (event) ->
            return if !active?

            if active.isCreating
                nextVisualEndDay = Math.max(active.initialStartDay, getEventTimelinePosition(event, active.svg, active.totalDays))
                if active.endLimit?.slotIndex?
                    nextVisualEndDay = Math.max(nextVisualEndDay, active.endLimit.slotIndex)
                nextVisualEndDay = Math.min(active.totalDays, nextVisualEndDay)

                nextEndDay = getSlotIndexForEvent(event, active.svg, active.totalDays)
                nextEndDay = Math.max(active.initialStartDay, nextEndDay)
                if active.endLimit?.slotIndex?
                    nextEndDay = Math.max(nextEndDay, active.endLimit.slotIndex)
                nextEndDay = Math.min(active.totalDays, nextEndDay)

                return if nextVisualEndDay == active.visualEndDay and nextEndDay == active.endDay

                active.endDay = nextEndDay
                active.visualEndDay = nextVisualEndDay
                active.bar.setAttribute("data-end-day", active.endDay)
                renderBarGeometry(
                    active.bar,
                    active.visualStartDay,
                    active.visualEndDay,
                    active.rowIndex,
                    active.totalDays
                )
                positionMoveLimitIndicators(active.bar, active)
                positionResizePopup(active.bar, active.startDay, active.endDay, "end")
                return

            deltaDays = (event.clientX - active.startX) / active.dayWidthPx
            nextVisualStartDay = active.initialStartDay
            nextVisualEndDay = active.initialEndDay
            startMinDay = 1
            startMaxDay = active.initialEndDay

            minMoveDelta = null
            maxMoveDelta = null

            if active.edge == "move"
                minDelta = 1 - active.initialStartDay
                maxDelta = active.totalDays - active.initialEndDay

                if active.startLimit?.slotIndex?
                    maxDelta = Math.min(maxDelta, active.startLimit.slotIndex - active.initialStartDay)

                if active.endLimit?.slotIndex?
                    minDelta = Math.max(minDelta, active.endLimit.slotIndex - active.initialEndDay)

                if active.startMinLimit?.slotIndex?
                    minDelta = Math.max(minDelta, active.startMinLimit.slotIndex - active.initialStartDay)

                if minDelta > maxDelta
                    minDelta = 0
                    maxDelta = 0

                moveDelta = Math.max(minDelta, Math.min(deltaDays, maxDelta))
                nextVisualStartDay = active.initialStartDay + moveDelta
                nextVisualEndDay = active.initialEndDay + moveDelta
                minMoveDelta = minDelta
                maxMoveDelta = maxDelta
            else if active.edge == "start"
                if active.limit?.slotIndex?
                    startMaxDay = Math.min(startMaxDay, active.limit.slotIndex)
                if active.startMinLimit?.slotIndex?
                    startMinDay = Math.max(startMinDay, active.startMinLimit.slotIndex)

                if startMinDay > startMaxDay
                    startMinDay = startMaxDay

                nextVisualStartDay = active.initialStartDay + deltaDays
                nextVisualStartDay = Math.max(startMinDay, Math.min(startMaxDay, nextVisualStartDay))
                if active.limit?.slotIndex?
                    nextVisualStartDay = Math.min(nextVisualStartDay, active.limit.slotIndex)
            else
                nextVisualEndDay = Math.min(active.totalDays, Math.max(active.initialStartDay, active.initialEndDay + deltaDays))
                if active.limit?.slotIndex?
                    nextVisualEndDay = Math.max(nextVisualEndDay, active.limit.slotIndex)

            if active.edge == "move"
                roundedDelta = Math.round(nextVisualStartDay - active.initialStartDay)
                roundedDelta = Math.max(Math.ceil(minMoveDelta), Math.min(roundedDelta, Math.floor(maxMoveDelta)))
                nextStartDay = active.initialStartDay + roundedDelta
                nextEndDay = active.initialEndDay + roundedDelta
            else
                nextStartDay = Math.round(nextVisualStartDay)
                nextEndDay = Math.round(nextVisualEndDay)
                nextStartDay = Math.max(1, Math.min(active.initialEndDay, nextStartDay))
                nextEndDay = Math.min(active.totalDays, Math.max(active.initialStartDay, nextEndDay))

            if active.edge == "move"
                if active.startLimit?.slotIndex?
                    nextStartDay = Math.min(nextStartDay, active.startLimit.slotIndex)
                if active.endLimit?.slotIndex?
                    nextEndDay = Math.max(nextEndDay, active.endLimit.slotIndex)
                if active.startMinLimit?.slotIndex?
                    nextStartDay = Math.max(nextStartDay, active.startMinLimit.slotIndex)
            else if active.edge == "start"
                if active.limit?.slotIndex?
                    nextStartDay = Math.min(nextStartDay, active.limit.slotIndex)
                if active.startMinLimit?.slotIndex?
                    nextStartDay = Math.max(nextStartDay, active.startMinLimit.slotIndex)
            else if active.edge == "end" and active.limit?.slotIndex?
                nextEndDay = Math.max(nextEndDay, active.limit.slotIndex)

            return if nextVisualStartDay == active.visualStartDay and nextVisualEndDay == active.visualEndDay

            active.startDay = nextStartDay
            active.endDay = nextEndDay
            active.visualStartDay = nextVisualStartDay
            active.visualEndDay = nextVisualEndDay

            active.bar.setAttribute("data-start-day", active.startDay)
            active.bar.setAttribute("data-end-day", active.endDay)
            renderBarGeometry(
                active.bar,
                active.visualStartDay,
                active.visualEndDay,
                active.rowIndex,
                active.totalDays
            )
            if active.edge == "move"
                positionMoveLimitIndicators(active.bar, active)
            else if active.edge == "start"
                positionStartLimitIndicators(active.bar)
            else
                positionLimitIndicator(active.bar, active.edge)
            positionResizePopup(active.bar, active.startDay, active.endDay, active.edge)

        startDrag = (bar, edge, event) ->
            return if !bar?
            return if isBarInteractionLocked()
            svg = getSvgForBar(bar)
            return if !svg?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)

            svgRect = svg.getBoundingClientRect()
            return if svgRect.width <= 0

            dayWidthPx = svgRect.width / totalDays
            return if !isFinite(dayWidthPx) or dayWidthPx <= 0

            rowId = bar.getAttribute("data-gantt-row-id")
            return if !rowId?

            ctrl = $scope.ctrl
            return if ctrl?.savingRows?[rowId]

            initialStartDay = parseInt(bar.getAttribute("data-start-day") or "1", 10)
            initialEndDay = parseInt(bar.getAttribute("data-end-day") or "#{initialStartDay}", 10)
            initialStartDay = Math.max(1, initialStartDay)
            initialEndDay = Math.max(initialStartDay, initialEndDay)

            storedRowIndex = parseInt(bar.getAttribute("data-row-index") or "", 10)
            rowIndex = if !isNaN(storedRowIndex) then storedRowIndex else getVisibleRowIndex(rowId)
            resizeLimit = if edge == "move" then null else getResizeLimit(bar, edge)
            startLimit = getResizeLimit(bar, "start")
            endLimit = getResizeLimit(bar, "end")
            startMinLimit = getResizeLimit(bar, "dependencyStart")

            active = {
                bar: bar
                edge: edge
                rowId: rowId
                startX: event.clientX
                dayWidthPx: dayWidthPx
                totalDays: totalDays
                rowIndex: rowIndex
                initialStartDay: initialStartDay
                initialEndDay: initialEndDay
                startDay: initialStartDay
                endDay: initialEndDay
                visualStartDay: initialStartDay
                visualEndDay: initialEndDay
                limit: resizeLimit
                startLimit: startLimit
                endLimit: endLimit
                startMinLimit: startMinLimit
            }

            clearHover()
            if edge == "move"
                root.classList.add(MOVE_DRAG_CLASS)
                bar.classList.add("is-move-bar")
            else
                root.classList.add(DRAG_CLASS)
            bar.classList.add("is-dragging")
            if edge == "move"
                positionMoveLimitIndicators(bar, active)
            else if edge == "start"
                positionStartLimitIndicators(bar)
            else
                positionLimitIndicator(bar, edge)
            positionResizePopup(bar, active.startDay, active.endDay, edge)
            $document.on("mousemove", onDragMouseMove)
            $document.on("mouseup", stopDrag)

        startCreateBar = (event) ->
            return false if isBarInteractionLocked()
            return false if !isEventInsideTimelineGrid(event)

            svg = getBarsSvg()
            return false if !svg?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)

            svgRect = svg.getBoundingClientRect()
            return false if svgRect.width <= 0

            rowData = getGridRowForEvent(event)
            return false if !rowData?

            rowId = rowData.rowId
            return false if findBarByRowId(rowId)?
            return false if !canCreateBarForRow(rowId)

            row = getRowModel(rowId)
            return false if !row?

            startLimit = getResizeLimitForRow(rowId, "start")
            endLimit = getResizeLimitForRow(rowId, "end")
            startMinLimit = getResizeLimitForRow(rowId, "dependencyStart")
            startDay = getSlotIndexForEvent(event, svg, totalDays)
            startDay = Math.min(startDay, startLimit.slotIndex) if startLimit?.slotIndex?
            startDay = Math.max(startDay, startMinLimit.slotIndex) if startMinLimit?.slotIndex?
            startDay = clamp(startDay, 1, totalDays)

            endDay = startDay
            endDay = Math.max(endDay, endLimit.slotIndex) if endLimit?.slotIndex?
            endDay = clamp(endDay, startDay, totalDays)

            clearHover()
            root.classList.add(CREATE_DRAG_CLASS)

            bar = createPreviewBar(svg, rowId, row, startDay, endDay, rowData.rowIndex, totalDays)
            bar.classList.add("is-dragging")

            active = {
                isCreating: true
                bar: bar
                svg: svg
                edge: "create"
                rowId: rowId
                startX: event.clientX
                totalDays: totalDays
                rowIndex: rowData.rowIndex
                initialStartDay: startDay
                initialEndDay: endDay
                startDay: startDay
                endDay: endDay
                visualStartDay: startDay
                visualEndDay: endDay
                startLimit: startLimit
                endLimit: endLimit
                startMinLimit: startMinLimit
            }

            positionMoveLimitIndicators(bar, active)
            positionResizePopup(bar, active.startDay, active.endDay, "end")
            $document.on("mousemove", onDragMouseMove)
            $document.on("mouseup", stopDrag)
            return true

        onHoverMouseMove = (event) ->
            return if active? or activeLinkDrag?

            hoveredBarElement = getNearestBarElement(event.target)
            if hoveredBarElement? and !hoveredBarElement.classList.contains("is-hidden")
                setVisibleLinkSourceCapsForRow(hoveredBarElement.getAttribute("data-gantt-row-id"))
            else
                setVisibleLinkSourceCapsForRow(null)

            if isBarLinkModeActive()
                bar = hoveredBarElement
                if !bar? or bar.classList.contains("is-hidden")
                    clearLinkHover()
                    clearHover()
                    return

                setLinkHover(bar)
                return

            clearLinkHover()

            if isBarInteractionLocked()
                clearHover()
                return

            bar = hoveredBarElement

            if !bar? or bar.classList.contains("is-hidden")
                clearHover()
                return

            if !isBarEditable(bar)
                clearHover()
                return

            edge = resolveResizeEdge(bar, event) or "move"
            setHover(bar, edge)

        onMouseDown = (event) ->
            return if event.button? and event.button != 0
            return if active? or activeLinkDrag?

            if isBarLinkModeActive()
                bar = getNearestBarElement(event.target)
                return if !bar? or bar.classList.contains("is-hidden")

                rowId = bar.getAttribute("data-gantt-row-id")
                return if !rowId?

                event.preventDefault()
                event.stopPropagation()

                started = startLinkDrag(bar, event)
                if !started and $scope.ctrl?.registerGanttBarLinkClick?(rowId)
                    $scope.$evalAsync()
                return

            return if isBarInteractionLocked()

            bar = getNearestBarElement(event.target)

            if !bar? or bar.classList.contains("is-hidden")
                return if !startCreateBar(event)

                event.preventDefault()
                event.stopPropagation()
                return

            return if !isBarEditable(bar)

            edge = resolveResizeEdge(bar, event) or "move"

            event.preventDefault()
            event.stopPropagation()
            startDrag(bar, edge, event)

        onMouseLeave = ->
            return if active? or activeLinkDrag?
            clearHover()
            clearLinkHover()
            setVisibleLinkSourceCapsForRow(null)

        unwatchBarLock = $scope.$watch("ctrl.barsLocked", (locked) ->
            return if !locked
            stopDrag()
            stopLinkDrag(null, {cancel: true})
            clearHover()
        )

        unwatchBarLinkMode = $scope.$watch("ctrl.barLinkModeActive", (activeLinkMode) ->
            return if activeLinkMode
            stopLinkDrag(null, {cancel: true})
            clearLinkHover()
            setVisibleLinkSourceCapsForRow(null)
        )
        unwatchBarLinks = $scope.$watchCollection("ctrl.barLinks", ->
            return if !visibleLinkSourceCapsRowId?
            setVisibleLinkSourceCapsForRow(visibleLinkSourceCapsRowId, true)
        )

        rightPanel.addEventListener("mousemove", onHoverMouseMove)
        rightPanel.addEventListener("mousedown", onMouseDown)
        rightPanel.addEventListener("mouseleave", onMouseLeave)

        $scope.$on "$destroy", ->
            rightPanel.removeEventListener("mousemove", onHoverMouseMove)
            rightPanel.removeEventListener("mousedown", onMouseDown)
            rightPanel.removeEventListener("mouseleave", onMouseLeave)
            clearHover()
            clearLinkHover()
            setVisibleLinkSourceCapsForRow(null)
            edgeIndicator.remove()
            limitIndicator.remove()
            moveEndLimitIndicator.remove()
            resizePopup.remove()
            stopDrag()
            stopLinkDrag(null, {cancel: true})
            linkDragPreviewPath?.remove()
            linkDragPreviewArrowhead?.remove()
            clearHoverSourceCaps()
            hoverSourceCapLayer?.remove()
            hoverSourceCapLayer = null
            visibleLinkSourceCapsRowId = null
            unwatchBarLock?()
            unwatchBarLinkMode?()
            unwatchBarLinks?()

    return {link: link}

module.directive("tgGanttBarResize", ["$document", GanttBarResizeDirective])
