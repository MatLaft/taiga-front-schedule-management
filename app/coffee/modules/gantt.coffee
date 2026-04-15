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

        @loading = false
        @loadingError = false
        @tree = []
        @ganttBars = []
        @timeline = @_emptyTimeline()
        @membersById = {}
        @rowNodesById = {}
        @savingRows = {}

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
        @tree = @_buildTree(epics, userstories, tasks)
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

    saveBarDateRange: (rowId, startDay, endDay) ->
        row = @rowNodesById[rowId]
        return @q.when() if !row?.item?

        normalizedStartDay = Math.max(1, parseInt(startDay, 10) or 1)
        normalizedEndDay = Math.max(normalizedStartDay, parseInt(endDay, 10) or normalizedStartDay)

        startMoment = @timeline.start.clone().add(normalizedStartDay - 1, "days").startOf("day")
        dueMoment = @timeline.start.clone().add(normalizedEndDay - 1, "days").startOf("day")

        startField = @_getStartEditableField(row.item)
        nextStartValue = startMoment.format("YYYY-MM-DD")
        nextDueValue = dueMoment.format("YYYY-MM-DD")
        currentStartValue = @_normalizeDateForInput(row.item[startField])
        currentDueValue = @_normalizeDateForInput(row.item.due_date)

        return @q.when() if currentStartValue == nextStartValue and currentDueValue == nextDueValue

        row.item.setAttr(startField, nextStartValue)
        row.item.setAttr("due_date", nextDueValue)
        @savingRows[rowId] = true

        return @repo.save(row.item, true, {include_schedule: true}).then =>
            delete @savingRows[rowId]

            row.startMoment = startMoment
            row.dueMoment = dueMoment
            row.startLabel = @_formatDateShort(startMoment)
            row.dueLabel = @_formatDateShort(dueMoment)

            @_refreshComputedData()
            return
        , =>
            row.item.revert()
            delete @savingRows[rowId]
            @confirm.notify("error")
            @_refreshComputedData()
            return @q.reject()

    _buildTree: (epics, userstories, tasks) ->
        epicNodes = _.map(@_sortById(epics), (epic) => @_buildNode("epic", epic))
        epicNodesById = {}
        rootStoryNodes = []
        rootTaskNodes = []

        _.each(epicNodes, (epicNode) ->
            epicNodesById["#{epicNode.item.id}"] = epicNode
        )

        storyNodesById = {}

        _.each(@_sortById(userstories), (story) =>
            storyNode = @_buildNode("story", story)
            storyNodesById["#{story.id}"] = storyNode

            epicId = @_extractEpicId(story, epicNodesById)
            parentEpic = epicNodesById["#{epicId}"]

            if parentEpic?
                parentEpic.children.push(storyNode)
            else
                rootStoryNodes.push(storyNode)
        )

        _.each(@_sortById(tasks), (task) =>
            taskNode = @_buildNode("task", task)
            storyId = @_extractStoryId(task)
            parentStory = storyNodesById["#{storyId}"]

            if parentStory?
                parentStory.children.push(taskNode)
            else
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

    _emptyTimeline: ->
        now = moment().startOf("day")
        widthRem = @dayWidthRem

        return {
            start: now.clone()
            end: now.clone()
            months: [{
                key: now.format("YYYY-MM")
                label: now.format("MMM YYYY")
                days: 1
                widthRem: widthRem
            }]
            days: [{
                key: now.format("YYYY-MM-DD")
                label: now.date()
            }]
            totalDays: 1
            rowCount: 1
            timelineWidthRem: widthRem
            dayColumnsStyle: {"grid-template-columns": "repeat(1, #{widthRem}rem)"}
            gridStyle: {width: "#{widthRem}rem"}
            svgStyle: {width: "#{widthRem}rem", height: "100%"}
        }

    _buildTimeline: (rows) ->
        allDates = []

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

        start = start.clone().subtract(1, "day").startOf("day")
        end.endOf("month")

        months = []
        monthCursor = start.clone().startOf("month")

        while monthCursor.isSameOrBefore(end, "month")
            monthStart = monthCursor.clone().startOf("month")
            monthEnd = monthCursor.clone().endOf("month")

            visibleStart = if monthStart.isBefore(start) then start.clone() else monthStart
            visibleEnd = if monthEnd.isAfter(end) then end.clone() else monthEnd
            visibleDays = visibleEnd.diff(visibleStart, "days") + 1

            months.push({
                key: monthCursor.format("YYYY-MM")
                label: monthCursor.format("MMM YYYY")
                days: visibleDays
                widthRem: visibleDays * @dayWidthRem
            })

            monthCursor.add(1, "month")

        days = []
        dayCursor = start.clone()

        while dayCursor.isSameOrBefore(end, "day")
            days.push({
                key: dayCursor.format("YYYY-MM-DD")
                label: dayCursor.date()
            })

            dayCursor.add(1, "day")

        totalDays = Math.max(days.length, 1)
        rowCount = Math.max((rows or []).length, 1)
        timelineWidthRem = totalDays * @dayWidthRem

        return {
            start: start
            end: end
            months: months
            days: days
            totalDays: totalDays
            rowCount: rowCount
            timelineWidthRem: timelineWidthRem
            dayColumnsStyle: {"grid-template-columns": "repeat(#{totalDays}, #{@dayWidthRem}rem)"}
            gridStyle: {width: "#{timelineWidthRem}rem"}
            svgStyle: {width: "#{timelineWidthRem}rem", height: "100%"}
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

            startDay = barStartMoment.diff(timeline.start, "days") + 1
            endDay = barEndMoment.diff(timeline.start, "days") + 1
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

        getColumnVar = (key) -> "--gantt-col-#{key}"

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

        onMouseMove = (event) ->
            return if !active?

            deltaX = event.clientX - active.startX
            minWidth = minWidths[active.key] or 80
            nextWidth = Math.max(minWidth, Math.round(active.startWidth + deltaX))

            root.style.setProperty(getColumnVar(active.key), "#{nextWidth}px")
            updateTableWidth()

        stopDrag = ->
            return if !active?

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

        $scope.$evalAsync(updateTableWidth)

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

        getMinWidth = (node) ->
            minWidth = parseFloat(window.getComputedStyle(node).minWidth or "")
            if isNaN(minWidth) then 0 else minWidth

        setLeftWidth = (requestedWidth) ->
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

            workspace.style.setProperty("--gantt-left-panel-width", "#{Math.round(bounded)}px")

        onMouseMove = (event) ->
            return if !active?

            rect = workspace.getBoundingClientRect()
            handleWidth = active.handleWidth or 0
            nextWidth = event.clientX - rect.left - (handleWidth / 2)
            setLeftWidth(nextWidth)

        stopDrag = ->
            return if !active?

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
            setLeftWidth(currentWidth + delta)

        handleEl = angular.element(handle)
        handleEl.on("mousedown", startDrag)
        handleEl.on("keydown", onKeydown)

        $scope.$evalAsync ->
            setLeftWidth(leftPanel.getBoundingClientRect().width)

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
        return if !leftPanel?

        getBarsData = ->
            barsSvg = root.querySelector(".gantt-bars-svg")
            bars = if barsSvg? then Array.from(root.querySelectorAll(".gantt-bar[data-gantt-row-id]")) else []

            return {
                barsSvg: barsSvg
                bars: bars
            }

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

                startDay = parseFloat(bar.getAttribute("data-start-day") or "1") or 1
                endDay = parseFloat(bar.getAttribute("data-end-day") or startDay) or startDay
                shape = bar.getAttribute("data-shape") or "arrow"
                barType = bar.getAttribute("data-bar-type") or ""
                bar.setAttribute("data-row-index", rowIndex)

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

        onChange = (event) ->
            target = event.target
            return if !target?.classList?.contains("gantt-node-trigger")
            updateVisibleRows()

        observer = null
        scheduleUpdate = _.debounce(updateVisibleRows, 10)

        if window.MutationObserver?
            observer = new MutationObserver ->
                scheduleUpdate()

            observer.observe(leftPanel, {childList: true, subtree: true})

            rightPanel = root.querySelector(".gantt-right-panel")
            if rightPanel?
                observer.observe(rightPanel, {childList: true, subtree: true})

        leftPanel.addEventListener("change", onChange)
        $scope.$evalAsync(updateVisibleRows)

        $scope.$on "$destroy", ->
            leftPanel.removeEventListener("change", onChange)
            observer.disconnect() if observer?

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
        INDICATOR_GAP_PX = -
        INDICATOR_PAD_Y_PX = 4
        hoveredBar = null
        hoveredEdge = null
        edgeIndicator = document.createElementNS(SVG_NS, "svg")
        edgeIndicator.setAttribute("class", "gantt-edge-indicator")
        edgeIndicatorLine = document.createElementNS(SVG_NS, "path")
        edgeIndicatorLine.classList.add("gantt-edge-indicator-line")
        edgeIndicatorArrow = document.createElementNS(SVG_NS, "path")
        edgeIndicatorArrow.classList.add("gantt-edge-indicator-arrow")
        edgeIndicator.appendChild(edgeIndicatorLine)
        edgeIndicator.appendChild(edgeIndicatorArrow)
        rightPanel.appendChild(edgeIndicator)

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

        stopDrag = ->
            return if !active?

            finishedDrag = active
            active = null
            root.classList.remove(DRAG_CLASS)
            finishedDrag.bar?.classList?.remove("is-dragging")
            $document.off("mousemove", onDragMouseMove)
            $document.off("mouseup", stopDrag)

            changed = finishedDrag.startDay != finishedDrag.initialStartDay or finishedDrag.endDay != finishedDrag.initialEndDay
            return if !changed

            ctrl = $scope.ctrl
            return if !ctrl?.saveBarDateRange?

            ctrl.saveBarDateRange(finishedDrag.rowId, finishedDrag.startDay, finishedDrag.endDay)

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
            $document.on("mousemove", onDragMouseMove)
            $document.on("mouseup", stopDrag)

        onHoverMouseMove = (event) ->
            return if active?

            bar = getNearestBarElement(event.target)

            if !bar? or bar.classList.contains("is-hidden")
                clearHover()
                return

            edge = resolveResizeEdge(bar, event)
            setHover(bar, edge)

        onMouseDown = (event) ->
            return if event.button? and event.button != 0
            return if active?

            bar = getNearestBarElement(event.target)
            return if !bar? or bar.classList.contains("is-hidden")

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
            stopDrag()

    return {link: link}

module.directive("tgGanttBarResize", ["$document", GanttBarResizeDirective])
