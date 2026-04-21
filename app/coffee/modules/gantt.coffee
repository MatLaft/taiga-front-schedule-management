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
        "tgErrorHandlingService"
    ]

    constructor: (@scope, @q, @repo, @confirm, @translate, @projectService, @errorHandlingService) ->
        bindMethods(@)

        @scope.sectionName = "PROJECT.SECTION.GANTT"
        @dayWidthRem = 2.2
        @weekWidthRem = 7
        @monthDayWidthRem = 0.35

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
        @colorList = getDefaulColorList()
        @activeColorMenuRowId = null
        @nodeCustomColorByRowId = {}
        @zoomMenuOpen = false
        @selectedZoomOption = "daily"

        @documentClickHandler = (event) => @onDocumentClick(event)
        angular.element(document).on("click", @documentClickHandler)
        @scope.$on "$destroy", =>
            angular.element(document).off("click", @documentClickHandler)

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
        @_restoreZoomOptionFromCookie()
        return @load()

    load: ->
        return @q.when() if !@scope.projectId

        @loading = true
        @loadingError = false

        promises = [
            @repo.queryMany("epics", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("userstories", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("tasks", {project: @scope.projectId, include_schedule: true})
        ]

        return @q.all(promises).then (result) =>
            [epics, userstories, tasks] = result
            @buildGanttData(epics or [], userstories or [], tasks or [])
            @loading = false
        , (xhr) =>
            @loading = false
            @loadingError = true

            if xhr?.status != 403 and xhr?.status != 404
                @confirm.notify("error")

            return @q.reject(xhr)

    buildGanttData: (epics, userstories, tasks) ->
        @sourceEpics = epics or []
        @sourceUserstories = userstories or []
        @sourceTasks = tasks or []

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
        @timeline = @_buildTimeline(flatRows)
        @ganttBars = @_buildBars(flatRows, @timeline)

    _normalizeDateForInput: (dateValue) ->
        return null if !dateValue

        parsed = moment(dateValue)
        return dateValue if !parsed.isValid()

        return parsed.format("YYYY-MM-DD")

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

    _getZoomCookieName: ->
        return buildGanttCookieName("layout_zoom", @scope)

    _persistZoomOption: ->
        cookieName = @_getZoomCookieName()
        writeGanttCookie(cookieName, @selectedZoomOption)

    _restoreZoomOptionFromCookie: ->
        cookieName = @_getZoomCookieName()
        option = readGanttCookie(cookieName)
        validOptions = ["daily", "weekly", "monthly"]
        return if validOptions.indexOf(option) == -1
        @selectedZoomOption = option

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

        @timelineStartAnchor = null
        @_refreshComputedData()
        @scope.$evalAsync()

    _getTimelineScale: ->
        return "weekly" if @selectedZoomOption == "weekly"
        return "monthly" if @selectedZoomOption == "monthly"
        return "daily"

    _getColumnWidthRem: (scale = @_getTimelineScale()) ->
        return @weekWidthRem if scale == "weekly"
        return @monthDayWidthRem * 30 if scale == "monthly"
        return @dayWidthRem

    _getTimelineSlotWidthRem: (scale = @_getTimelineScale()) ->
        columnWidthRem = @_getColumnWidthRem(scale)
        return (columnWidthRem / 7) if scale == "weekly"
        return @monthDayWidthRem if scale == "monthly"
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

        if @activeColorMenuRowId?
            if !@_hasAncestorWithClass(target, "gantt-row-type-icon")
                @activeColorMenuRowId = null
                shouldRefreshScope = true

        if @zoomMenuOpen
            if !@_hasAncestorWithClass(target, "gantt-toolbar-zoom")
                @zoomMenuOpen = false
                shouldRefreshScope = true

        @scope.$evalAsync() if shouldRefreshScope

    toggleNodeColorMenu: (event, row) ->
        @stopColorMenuEvent(event)
        return if !@canEditNodeColor(row)

        if @activeColorMenuRowId == row?.rowId
            @activeColorMenuRowId = null
            return

        @activeColorMenuRowId = row.rowId
        target = @_getTargetNodeForColorChange(row)
        @nodeCustomColorByRowId[row.rowId] = @_normalizeColorValue(target?.item?.color)

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

    selectNodeColor: (event, row, color) ->
        @stopColorMenuEvent(event)
        return @q.when() if !row?

        normalizedColor = @_normalizeColorValue(color)
        return @q.when() if !normalizedColor?

        target = @_getTargetNodeForColorChange(row)
        return @q.reject() if !target?
        return @q.reject() if !@_canModifyType(target.type)

        currentColor = @_normalizeColorValue(target.item?.color)
        return @q.when() if currentColor == normalizedColor

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

            @activeColorMenuRowId = null
            @timelineStartAnchor = null
            @buildGanttData(@sourceEpics, @sourceUserstories, @sourceTasks)
            @scope.$evalAsync()
            @confirm.notify("success")
            return
        , =>
            target.item.revert()
            _.each(affectedRows, (affectedRowId) =>
                delete @savingRows[affectedRowId]
            )
            @confirm.notify("error")
            return @q.reject()

    saveBarDateRange: (rowId, startDay, endDay) ->
        row = @rowNodesById[rowId]
        return @q.reject() if !row?.item? or !row.canEdit

        normalizedStartDay = Math.max(1, parseInt(startDay, 10) or 1)
        normalizedEndDay = Math.max(normalizedStartDay, parseInt(endDay, 10) or normalizedStartDay)

        startMoment = @_getTimelineMomentBySlotIndex(normalizedStartDay)
        dueMoment = @_getTimelineMomentBySlotIndex(normalizedEndDay)
        return @q.reject() if !startMoment? or !dueMoment?

        startField = @_getStartEditableField(row.item)
        nextStartValue = startMoment.format("YYYY-MM-DD")
        nextDueValue = dueMoment.format("YYYY-MM-DD")
        currentStartValue = @_normalizeDateForInput(row.item[startField])
        currentDueValue = @_normalizeDateForInput(row.item.due_date)

        return @q.when() if currentStartValue == nextStartValue and currentDueValue == nextDueValue

        affectedEntities = @_collectAffectedEntitiesForDateSave(row)

        row.item.setAttr(startField, nextStartValue)
        row.item.setAttr("due_date", nextDueValue)
        @savingRows[rowId] = true

        return @repo.save(row.item, true, {include_schedule: true}).then =>
            delete @savingRows[rowId]
            return @_reloadDateAffectedEntities(affectedEntities).then =>
                @confirm.notify("success")
                return
            , =>
                @timelineStartAnchor = null
                @buildGanttData(@sourceEpics, @sourceUserstories, @sourceTasks)
                @scope.$evalAsync()
                @confirm.notify("success")
                return
        , (errorData) =>
            row.item.revert()
            delete @savingRows[rowId]
            message = @_extractApiErrorMessage(errorData)
            @confirm.notify("error", message)
            return @q.reject()

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
        epicNodes = _.map(@_sortById(epics), (epic) => @_buildNode("epic", epic))
        epicNodesById = {}
        rootStoryNodes = []
        rootTaskNodes = []

        _.each(epicNodes, (epicNode) =>
            epicNodesById["#{epicNode.item.id}"] = epicNode
            epicNode.epicId = @_normalizeId(epicNode.item?.id)
            epicNode.barColor = @_extractEpicColor(epicNode.item)
        )

        storyNodesById = {}

        _.each(@_sortById(userstories), (story) =>
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

        _.each(@_sortById(tasks), (task) =>
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

    _buildResizeLimitData: (targetMoment, edge, timeline) ->
        return null if !targetMoment? or !timeline?

        slotIndex = @_findTimelineSlotIndexForMoment(targetMoment, timeline)
        position = if edge == "start" then slotIndex - 1 else slotIndex
        position = Math.max(0, Math.min(timeline.totalDays, position))

        return {
            slotIndex: slotIndex
            position: position
        }

    _buildResizeLimits: (row, timeline) ->
        descendants = @_getDescendantRows(row)
        return null if !descendants.length

        descendantRowIds = []
        earliestStartMoment = null
        latestDueMoment = null

        _.each(descendants, (child) ->
            descendantRowIds.push(child.rowId) if child.rowId?

            if child.startMoment?
                if !earliestStartMoment? or child.startMoment.isBefore(earliestStartMoment, "day")
                    earliestStartMoment = child.startMoment.clone()

            if child.dueMoment?
                if !latestDueMoment? or child.dueMoment.isAfter(latestDueMoment, "day")
                    latestDueMoment = child.dueMoment.clone()
        )

        startLimit = @_buildResizeLimitData(earliestStartMoment, "start", timeline)
        endLimit = @_buildResizeLimitData(latestDueMoment, "end", timeline)

        return null if !startLimit? and !endLimit?

        return {
            descendantRowIds: descendantRowIds
            start: startLimit
            end: endLimit
        }

    _buildBars: (rows, timeline) ->
        rowIndexesById = {}
        bars = []

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
                bar.rect = @_buildRoundedRect(startDay, endDay, rowIndex, timeline.totalDays)
            else if barType == "story"
                bar.pathD = @_buildStoryPath(startDay, endDay, rowIndex, timeline.totalDays)
            else
                bar.pathD = @_buildEpicPath(startDay, endDay, rowIndex, timeline.totalDays)

            bars.push(bar)
        )

        return bars

    _buildEpicPath: (startDay, endDay, rowIndex, totalDays) ->
        left = Math.max(0, startDay - 1)
        right = Math.min(totalDays, endDay)
        top = rowIndex + 0.22
        bottom = rowIndex + 0.58
        tip = rowIndex + 0.74
        inset = 0.28
        return "M#{left},#{top}L#{right},#{top}L#{right},#{bottom}L#{right},#{tip}L#{right - inset},#{bottom}L#{left + inset},#{bottom}L#{left},#{tip}L#{left},#{bottom}z"

    _buildStoryPath: (startDay, endDay, rowIndex, totalDays) ->
        left = Math.max(0, startDay - 1)
        right = Math.min(totalDays, endDay)
        top = rowIndex + 0.22
        bottom = rowIndex + 0.58
        mid = (top + bottom) / 2
        span = Math.max(right - left, 0.5)
        notch = Math.min(0.28, span / 4)
        return "M#{left},#{top}L#{right},#{top}L#{right - notch},#{mid}L#{right},#{bottom}L#{left},#{bottom}L#{left + notch},#{mid}z"

    _buildRoundedRect: (startDay, endDay, rowIndex, totalDays) ->
        left = Math.max(0, startDay - 1)
        right = Math.min(totalDays, endDay)
        width = Math.max(right - left, .35)
        return {
            x: left
            y: rowIndex + 0.28
            width: width
            height: 0.50
            rx: 0.16
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
            bars = if barsSvg? then Array.from(root.querySelectorAll(".gantt-bar[data-gantt-row-id]")) else []

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

        buildEpicPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            tip = rowIndex + 0.74
            inset = 0.28
            "M#{left},#{top}L#{right},#{top}L#{right},#{bottom}L#{right},#{tip}L#{right - inset},#{bottom}L#{left + inset},#{bottom}L#{left},#{tip}L#{left},#{bottom}z"

        buildStoryPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            mid = (top + bottom) / 2
            span = Math.max(right - left, 0.5)
            notch = Math.min(0.28, span / 4)
            "M#{left},#{top}L#{right},#{top}L#{right - notch},#{mid}L#{right},#{bottom}L#{left},#{bottom}L#{left + notch},#{mid}z"

        buildRoundedRect = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            width = Math.max(right - left, .35)
            {
                x: left
                y: rowIndex + 0.28
                width: width
                height: 0.50
                rx: 0.16
                ry: 0.16
            }

        syncBars = (visibleRowMap, visibleRowsCount) ->
            barsData = getBarsData()
            barsSvg = barsData.barsSvg
            bars = barsData.bars
            return if !barsSvg?

            barsModelByRowId = getBarsModelByRowId()

            totalDays = parseFloat(barsSvg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)
            barsSvg.setAttribute("viewBox", "0 0 #{totalDays} #{Math.max(1, visibleRowsCount)}")

            bars.forEach (bar) ->
                rowId = bar.getAttribute("data-gantt-row-id")
                rowIndex = visibleRowMap[rowId]

                if rowIndex == undefined
                    bar.classList.add("is-hidden")
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

        updateVisibleRows = ->
            rows = Array.from(leftPanel.querySelectorAll(".gantt-tree-row"))
            visibleRows = rows.filter((row) -> row.offsetParent?)
            visibleRowMap = {}

            visibleRows.forEach (row, index) ->
                rowId = row.getAttribute("data-gantt-row-id")
                return if !rowId?
                visibleRowMap[rowId] = index

            syncBars(visibleRowMap, visibleRows.length)

            visibleRowsCount = Math.max(visibleRows.length, 1)
            root.style.setProperty("--gantt-visible-rows", "#{visibleRowsCount}")
            updateRightPanelOverflow(visibleRows)

        onChange = (event) ->
            target = event.target
            return if !target?.classList?.contains("gantt-node-trigger")
            updateVisibleRows()

        observer = null
        scheduleUpdate = _.debounce(updateVisibleRows, 10)
        onWindowResize = _.debounce(updateVisibleRows, 25)
        unwatchBars = $scope.$watchCollection("ctrl.ganttBars", ->
            _.defer(scheduleUpdate)
        )
        unwatchTimelineStart = $scope.$watch("ctrl.timeline.start", ->
            _.defer(scheduleUpdate)
        )
        unwatchTimelineDays = $scope.$watch("ctrl.timeline.totalDays", ->
            _.defer(scheduleUpdate)
        )

        if window.MutationObserver?
            observer = new MutationObserver ->
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
            unwatchTimelineStart?()
            unwatchTimelineDays?()

    return {link: link}

module.directive("tgGanttSyncRows", [GanttSyncRowsDirective])

GanttBarResizeDirective = ($document) ->
    link = ($scope, $el) ->
        root = $el[0]
        leftPanel = root.querySelector(".gantt-left-panel")
        rightPanel = root.querySelector(".gantt-right-panel")
        return if !leftPanel? or !rightPanel?

        active = null
        DRAG_CLASS = "is-resizing-gantt-bar"
        HOVER_CLASS = "is-hovering-gantt-edge"
        SVG_NS = "http://www.w3.org/2000/svg"
        INDICATOR_FRAME_WIDTH = 10
        INDICATOR_ARROW_WIDTH = 6
        INDICATOR_WIDTH = INDICATOR_FRAME_WIDTH + INDICATOR_ARROW_WIDTH
        INDICATOR_GAP_PX = 1
        INDICATOR_PAD_Y_PX = 4
        hoveredBar = null
        hoveredEdge = null
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

        getSvgForBar = (bar) ->
            node = bar
            while node?
                return node if node.tagName?.toLowerCase?() == "svg"
                node = node.parentNode
            return null

        buildEpicPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            tip = rowIndex + 0.74
            inset = 0.28
            "M#{left},#{top}L#{right},#{top}L#{right},#{bottom}L#{right},#{tip}L#{right - inset},#{bottom}L#{left + inset},#{bottom}L#{left},#{tip}L#{left},#{bottom}z"

        buildStoryPath = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            top = rowIndex + 0.22
            bottom = rowIndex + 0.58
            mid = (top + bottom) / 2
            span = Math.max(right - left, 0.5)
            notch = Math.min(0.28, span / 4)
            "M#{left},#{top}L#{right},#{top}L#{right - notch},#{mid}L#{right},#{bottom}L#{left},#{bottom}L#{left + notch},#{mid}z"

        buildRoundedRect = (startDay, endDay, rowIndex, totalDays) ->
            left = Math.max(0, startDay - 1)
            right = Math.min(totalDays, endDay)
            width = Math.max(right - left, .35)
            {
                x: left
                y: rowIndex + 0.28
                width: width
                height: 0.50
                rx: 0.16
                ry: 0.16
            }

        getVisibleRowIndex = (rowId) ->
            rows = Array.from(leftPanel.querySelectorAll(".gantt-tree-row"))
            visibleRows = rows.filter((row) -> row.offsetParent?)
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

        isBarEditable = (bar) ->
            return false if !bar?
            return bar.getAttribute("data-can-edit") == "true"

        getBarModel = (rowId) ->
            return null if !rowId?

            return _.find($scope.ctrl?.ganttBars or [], (barModel) ->
                return barModel?.rowId == rowId
            )

        getResizeLimit = (bar, edge) ->
            rowId = bar?.getAttribute("data-gantt-row-id")
            barModel = getBarModel(rowId)
            limits = barModel?.resizeLimits
            return null if !limits?

            edgeLimit = limits[edge]
            return null if !edgeLimit?.position?

            return {
                position: edgeLimit.position
                descendantRowIds: limits.descendantRowIds or []
            }

        getBarFillColor = (bar) ->
            return "" if !bar?

            computed = window.getComputedStyle(bar)
            fill = computed?.fill
            return fill if fill? and fill != "none" and fill != "rgba(0, 0, 0, 0)"

            return bar.getAttribute("fill") or ""

        findBarByRowId = (rowId) ->
            return null if !rowId?

            bars = Array.from(root.querySelectorAll(".gantt-bar[data-gantt-row-id]"))
            return _.find(bars, (candidate) ->
                return candidate.getAttribute("data-gantt-row-id") == rowId
            )

        clearLimitIndicator = ->
            limitIndicator.classList.remove("is-visible")

        positionLimitIndicator = (bar, edge) ->
            limit = getResizeLimit(bar, edge)
            return clearLimitIndicator() if !limit?

            svg = getSvgForBar(bar)
            return clearLimitIndicator() if !svg?

            totalDays = parseFloat(svg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)

            svgRect = svg.getBoundingClientRect()
            panelRect = rightPanel.getBoundingClientRect()
            barRect = bar.getBoundingClientRect()
            return clearLimitIndicator() if svgRect.width <= 0 or barRect.height <= 0

            x = svgRect.left - panelRect.left
            x += rightPanel.scrollLeft
            x += (limit.position / totalDays) * svgRect.width

            top = barRect.top - panelRect.top + rightPanel.scrollTop
            bottom = barRect.bottom - panelRect.top + rightPanel.scrollTop

            _.each(limit.descendantRowIds, (descendantRowId) ->
                descendantBar = findBarByRowId(descendantRowId)
                return if !descendantBar? or descendantBar.classList.contains("is-hidden")

                descendantRect = descendantBar.getBoundingClientRect()
                descendantBottom = descendantRect.bottom - panelRect.top + rightPanel.scrollTop
                bottom = Math.max(bottom, descendantBottom)
            )

            limitIndicator.style.left = "#{Math.round(x)}px"
            limitIndicator.style.top = "#{Math.round(top)}px"
            limitIndicator.style.height = "#{Math.max(1, Math.round(bottom - top))}px"
            limitIndicator.style.backgroundColor = getBarFillColor(bar)
            limitIndicator.classList.add("is-visible")

        clearHover = ->
            if hoveredBar?
                hoveredBar.classList.remove("is-resize-edge")
                hoveredBar.classList.remove("is-resize-start")
                hoveredBar.classList.remove("is-resize-end")

            hoveredBar = null
            hoveredEdge = null
            rightPanel.classList.remove(HOVER_CLASS)
            edgeIndicator.classList.remove("is-visible")
            edgeIndicator.classList.remove("is-start")
            edgeIndicator.classList.remove("is-end")
            clearLimitIndicator()

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
            hoveredBar.classList.add("is-resize-edge")
            hoveredBar.classList.add(if edge == "start" then "is-resize-start" else "is-resize-end")
            rightPanel.classList.add(HOVER_CLASS)
            positionEdgeIndicator(bar, edge)
            positionLimitIndicator(bar, edge)

        stopDrag = ->
            return if !active?

            finishedDrag = active
            active = null
            root.classList.remove(DRAG_CLASS)
            finishedDrag.bar?.classList?.remove("is-dragging")
            $document.off("mousemove", onDragMouseMove)
            $document.off("mouseup", stopDrag)
            clearLimitIndicator()

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

            deltaDays = Math.round((event.clientX - active.startX) / active.dayWidthPx)
            nextStartDay = active.initialStartDay
            nextEndDay = active.initialEndDay

            if active.edge == "start"
                nextStartDay = Math.max(1, Math.min(active.initialEndDay, active.initialStartDay + deltaDays))
            else
                nextEndDay = Math.min(active.totalDays, Math.max(active.initialStartDay, active.initialEndDay + deltaDays))

            return if nextStartDay == active.startDay and nextEndDay == active.endDay

            active.startDay = nextStartDay
            active.endDay = nextEndDay

            active.bar.setAttribute("data-start-day", active.startDay)
            active.bar.setAttribute("data-end-day", active.endDay)
            renderBarGeometry(active.bar, active.startDay, active.endDay, active.rowIndex, active.totalDays)
            positionLimitIndicator(active.bar, active.edge)

        startDrag = (bar, edge, event) ->
            return if !bar?
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
            }

            clearHover()
            root.classList.add(DRAG_CLASS)
            bar.classList.add("is-dragging")
            positionLimitIndicator(bar, edge)
            $document.on("mousemove", onDragMouseMove)
            $document.on("mouseup", stopDrag)

        onHoverMouseMove = (event) ->
            return if active?

            bar = getNearestBarElement(event.target)

            if !bar? or bar.classList.contains("is-hidden")
                clearHover()
                return

            if !isBarEditable(bar)
                clearHover()
                return

            edge = resolveResizeEdge(bar, event)
            setHover(bar, edge)

        onMouseDown = (event) ->
            return if event.button? and event.button != 0
            return if active?

            bar = getNearestBarElement(event.target)
            return if !bar? or bar.classList.contains("is-hidden")
            return if !isBarEditable(bar)

            edge = resolveResizeEdge(bar, event)
            return if !edge?

            event.preventDefault()
            event.stopPropagation()
            startDrag(bar, edge, event)

        onMouseLeave = ->
            return if active?
            clearHover()

        rightPanel.addEventListener("mousemove", onHoverMouseMove)
        rightPanel.addEventListener("mousedown", onMouseDown)
        rightPanel.addEventListener("mouseleave", onMouseLeave)

        $scope.$on "$destroy", ->
            rightPanel.removeEventListener("mousemove", onHoverMouseMove)
            rightPanel.removeEventListener("mousedown", onMouseDown)
            rightPanel.removeEventListener("mouseleave", onMouseLeave)
            clearHover()
            edgeIndicator.remove()
            limitIndicator.remove()
            stopDrag()

    return {link: link}

module.directive("tgGanttBarResize", ["$document", GanttBarResizeDirective])
