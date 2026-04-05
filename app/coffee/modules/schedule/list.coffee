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
        @.loading = false
        @.loadingError = false
        @.savingKey = null

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

        @lightboxFactory.create(
            "tg-lb-set-due-date",
            {"class": "lightbox lightbox-set-due-date"},
            {
                object: {
                    due_date: row.item[field]
                    due_date_reason: row.item.due_date_reason
                }
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
