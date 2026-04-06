###
# This source code is licensed under the terms of the
# GNU Affero General Public License found in the LICENSE file in
# the root directory of this source tree.
#
# Copyright (c) 2021-present Kaleidos INC
###

taiga = @.taiga
bindMethods = @.taiga.bindMethods
mixOf = @.taiga.mixOf

module = angular.module("taigaSchedule")

class ScheduleController extends mixOf(taiga.Controller, taiga.PageMixin)
    @.$inject = [
        "$scope",
        "$q",
        "$tgRepo",
        "$tgConfirm",
        "tgLightboxFactory",
        "$translate",
        "tgProjectService",
        "tgErrorHandlingService"
    ]

    constructor: (@scope, @q, @repo, @confirm, @lightboxFactory, @translate, @projectService, @errorHandlingService) ->
        bindMethods(@)

        @scope.sectionName = "PROJECT.SECTION.SCHEDULE"
        @.rows = []
        @.displayRows = []
        @.loading = false
        @.loadingError = false
        @.savingKey = null
        @.sortField = null
        @.typeOrderMode = null
        @.subjectSortDirection = null
        @.dateSortDirections = {}
        @._typeOrderCycles = [
            ["epic", "userstory", "task"]
            ["task", "userstory", "epic"]
        ]
        @._dateSortFields = ["estimated_start", "actual_start", "due_date"]

        promise = @.loadInitialData()

        promise.then null, @.onInitialDataError.bind(@)

    loadProject: ->
        project = @projectService.project.toJS()

        @scope.projectId = project.id
        @scope.project = project
        @scope.$emit('project:loaded', project)

    loadInitialData: ->
        @.loadProject()
        return @.load()

    load: ->
        return if !@scope.projectId

        @.loading = true
        @.loadingError = false

        promises = [
            @repo.queryMany("epics", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("userstories", {project: @scope.projectId, include_schedule: true})
            @repo.queryMany("tasks", {project: @scope.projectId, include_schedule: true})
        ]

        @q.all(promises).then (result) =>
            [epics, userstories, tasks] = result

            rows = []
            rows = rows.concat(@._toRows(epics, "epic", "Epic"))
            rows = rows.concat(@._toRows(userstories, "userstory", "History"))
            rows = rows.concat(@._toRows(tasks, "task", "Task"))

            @.rows = rows
            @.updateDisplayRows()
            @.loading = false
            return rows
        , (xhr) =>
            @.loading = false
            @.loadingError = true

            if xhr?.status != 403 and xhr?.status != 404
                @confirm.notify("error")

            return @q.reject(xhr)

    _toRows: (items, type, typeLabel) ->
        return _.map(items, (item) ->
            return {
                item: item
                type: type
                typeLabel: typeLabel
            }
        )

    cycleTypeOrder: ->
        @sortField = "type"

        if @typeOrderMode == null
            @typeOrderMode = 0
        else
            @typeOrderMode = (@typeOrderMode + 1) % @_typeOrderCycles.length

        @.updateDisplayRows()

    toggleSubjectOrder: ->
        @sortField = "subject"

        if @subjectSortDirection == null or @subjectSortDirection == "desc"
            @subjectSortDirection = "asc"
        else
            @subjectSortDirection = "desc"

        @.updateDisplayRows()

    toggleDateOrder: (field) ->
        return if @_dateSortFields.indexOf(field) == -1

        @sortField = field

        currentDirection = @dateSortDirections[field]
        @dateSortDirections[field] = if currentDirection == "asc" then "desc" else "asc"

        @.updateDisplayRows()

    getSortIconClass: (field) ->
        return "" if @sortField != field

        if field == "type"
            return if @typeOrderMode == 0 then "icon-arrow-down" else "icon-arrow-up"

        if field == "subject"
            return @_directionToIconClass(@subjectSortDirection)

        if @_dateSortFields.indexOf(field) != -1
            return @_directionToIconClass(@dateSortDirections[field])

        return ""

    updateDisplayRows: ->
        if @sortField == "type" and @typeOrderMode != null
            @displayRows = @._orderRowsByType()
            return

        if @sortField == "subject" and @subjectSortDirection?
            @displayRows = @._orderRowsBySubject(@subjectSortDirection)
            return

        if @_dateSortFields.indexOf(@sortField) != -1 and @dateSortDirections[@sortField]?
            @displayRows = @._orderRowsByDate(@sortField, @dateSortDirections[@sortField])
            return

        @displayRows = @rows

    _orderRowsByType: ->
        orderedTypes = @_typeOrderCycles[@typeOrderMode] or @_typeOrderCycles[0]
        groupedRows = _.groupBy(@rows, "type")
        orderedRows = []
        includedTypes = {}

        _.each(orderedTypes, (type) ->
            includedTypes[type] = true
            orderedRows = orderedRows.concat(groupedRows[type] or [])
        )

        _.each(@rows, (row) ->
            return if includedTypes[row.type]
            orderedRows.push(row)
        )

        return orderedRows

    _orderRowsBySubject: (direction) ->
        isDescending = direction == "desc"
        orderedRows = @rows.slice(0)

        orderedRows.sort (a, b) =>
            titleA = "#{@itemTitle(a)}"
            titleB = "#{@itemTitle(b)}"

            comparison = titleA.localeCompare(titleB, undefined, {sensitivity: "base"})

            if comparison == 0
                fallbackA = @rowKey(a)
                fallbackB = @rowKey(b)
                comparison = fallbackA.localeCompare(fallbackB)

            if isDescending then -comparison else comparison

        return orderedRows

    _orderRowsByDate: (field, direction) ->
        isDescending = direction == "desc"
        orderedRows = @rows.slice(0)

        orderedRows.sort (a, b) =>
            timestampA = @_toSortableTimestamp(a.item[field])
            timestampB = @_toSortableTimestamp(b.item[field])

            hasA = timestampA?
            hasB = timestampB?

            if !hasA and !hasB
                return @rowKey(a).localeCompare(@rowKey(b))

            # Keep empty dates at the end for both directions.
            return 1 if !hasA
            return -1 if !hasB

            comparison = timestampA - timestampB

            if comparison == 0
                comparison = @rowKey(a).localeCompare(@rowKey(b))

            if isDescending then -comparison else comparison

        return orderedRows

    _toSortableTimestamp: (dateValue) ->
        return null if !dateValue

        parsed = moment(dateValue)
        return null if !parsed.isValid()

        return parsed.valueOf()

    _directionToIconClass: (direction) ->
        return "" if !direction
        return if direction == "asc" then "icon-arrow-down" else "icon-arrow-up"

    rowKey: (row) ->
        return "#{row.type}-#{row.item.id}"

    itemTitle: (row) ->
        return row.item.subject or row.item.name or "-"

    formatDate: (dateValue) ->
        return "?" if !dateValue

        parsed = moment(dateValue)
        return dateValue if !parsed.isValid()

        return parsed.format("YYYY-MM-DD")

    getDateValue: (row, field) ->
        return row.item[field]

    isSaving: (row, field) ->
        return @savingKey == "#{@rowKey(row)}-#{field}"

    openDateLightbox: (row, field) ->
        return if @isSaving(row, field)
        isDueDateField = field == "due_date"
        fieldLabel = field.replace(/_/g, " ")
        title = if isDueDateField then @translate.instant("LIGHTBOX.SET_DUE_DATE.TITLE") else "Set #{fieldLabel}"

        @lightboxFactory.create(
            "tg-lb-set-due-date",
            {"class": "lightbox lightbox-set-due-date"},
            {
                object: {
                    due_date: row.item[field]
                    due_date_reason: if isDueDateField then row.item.due_date_reason else null
                }
                fieldName: field
                fieldLabel: fieldLabel
                lightboxTitle: title
                showSuggestions: true
                showDueDateReason: isDueDateField
                notAutoSave: true
                onSave: (newDueDate) => @saveFieldDate(row, field, newDueDate)
            }
        )

    saveFieldDate: (row, field, newDateValue) ->
        normalizedOriginal = @._normalizeDateForInput(row.item[field])
        normalizedNew = @._normalizeDateForInput(newDateValue)

        if normalizedOriginal == normalizedNew
            return @q.when()

        row.item.setAttr(field, normalizedNew)
        @savingKey = "#{@rowKey(row)}-#{field}"

        return @repo.save(row.item, true, {include_schedule: true}).then =>
            @savingKey = null
            return
        , =>
            row.item.revert()
            @savingKey = null
            @confirm.notify("error")
            return @q.reject()

    _normalizeDateForInput: (dateValue) ->
        return null if !dateValue

        parsed = moment(dateValue)
        return dateValue if !parsed.isValid()

        return parsed.format("YYYY-MM-DD")

module.controller("ScheduleController", ScheduleController)
