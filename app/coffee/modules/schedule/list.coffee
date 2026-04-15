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
        "tgErrorHandlingService",
        "tgFilterRemoteStorageService"
    ]

    constructor: (@scope, @q, @repo, @confirm, @lightboxFactory, @translate, @projectService, @errorHandlingService, @filterRemoteStorageService) ->
        bindMethods(@)

        @scope.sectionName = "PROJECT.SECTION.SCHEDULE"
        @.rows = []
        @.displayRows = []
        @.loading = false
        @.loadingError = false
        @.savingKey = null
        @.editingEstimatedHoursKey = null
        @.openFilter = false
        @.filterQ = ""
        @.showTags = true
        @.filters = []
        @.customFilters = []
        @.selectedFilters = []
        @._dateRangeFilterDefinitions = [
            {
                dataType: "estimated_start_range"
                field: "estimated_start"
                titleKey: "SCHEDULE.FILTERS.ESTIMATED_START_RANGE"
                labelKey: "SCHEDULE.TABLE.COLUMNS.ESTIMATED_START"
                configPrefix: "estimated_start"
            }
            {
                dataType: "actual_start_range"
                field: "actual_start"
                titleKey: "SCHEDULE.FILTERS.ACTUAL_START_RANGE"
                labelKey: "SCHEDULE.TABLE.COLUMNS.ACTUAL_START"
                configPrefix: "actual_start"
            }
            {
                dataType: "due_date_range"
                field: "due_date"
                titleKey: "SCHEDULE.FILTERS.DUE_DATE_RANGE"
                labelKey: "COMMON.FIELDS.DUE_DATE"
                configPrefix: "due_date"
            }
        ]
        @.dateRangeFilters = {}
        _.each(@._dateRangeFilterDefinitions, (definition) =>
            @dateRangeFilters[definition.field] = @_emptyDateRangeFilter()
        )
        @.dateRangePresetBaseDate = moment().startOf("day").format("YYYY-MM-DD")
        @.customFiltersStoreName = "schedule-my-filters"
        @.sortField = null
        @.typeOrderMode = null
        @.subjectSortDirection = null
        @.statusSortDirection = null
        @.estimatedHoursSortDirection = null
        @.dateSortDirections = {}
        @.projectMembersById = {}
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
        @projectMembersById = {}
        _.each(project.members or [], (member) =>
            return if !member?.id?
            @projectMembersById["#{member.id}"] = member
        )
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
            @filterRemoteStorageService.getFilters(@scope.projectId, @customFiltersStoreName)
        ]

        @q.all(promises).then (result) =>
            [epics, userstories, tasks, customFiltersRaw] = result

            rows = []
            rows = rows.concat(@._toRows(epics, "epic", "Epic"))
            rows = rows.concat(@._toRows(userstories, "userstory", "History"))
            rows = rows.concat(@._toRows(tasks, "task", "Task"))

            @.rows = rows
            @.setCustomFilters(customFiltersRaw)
            @.updateFilters()
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
        return _.map(items, (item) =>
            return {
                item: item
                type: type
                typeLabel: typeLabel
                tags: @._normalizeTags(item.tags)
                estimatedHoursInput: @_estimatedHoursInputFromItem(item)
            }
        )

    _normalizeTags: (tags) ->
        return [] if !tags?.length

        return _.chain(tags)
            .map (tag) ->
                if _.isArray(tag)
                    name = "#{tag[0] or ''}".trim()
                    color = tag[1] or "#8f96b2"
                else if _.isObject(tag)
                    name = "#{tag.name or tag.value or ''}".trim()
                    color = tag.color or "#8f96b2"
                else
                    name = "#{tag}".trim()
                    color = "#8f96b2"

                return null if !name.length
                return [name, color]
            .compact()
            .value()

    onFilterButtonClick: ->
        return

    changeQ: (q) ->
        @filterQ = q or ""
        @.updateFilters()
        @.updateDisplayRows()
        return

    toggleShowTags: ->
        return

    setDateRangeFilter: (range, dataType) ->
        definition = @_getDateRangeDefinitionByDataType(dataType)
        return if !definition?

        @dateRangeFilters[definition.field] = @_normalizeDateRange(range)
        @_syncDateRangeSelectedFilters()
        @.updateFilters()
        @.updateDisplayRows()

    clearDateRangeFilter: (dataType) ->
        definition = @_getDateRangeDefinitionByDataType(dataType)
        return if !definition?

        @dateRangeFilters[definition.field] = @_emptyDateRangeFilter()
        @_syncDateRangeSelectedFilters()
        @.updateFilters()
        @.updateDisplayRows()

    addFilter: (newFilter) ->
        filterCategory = newFilter?.category
        filterItem = newFilter?.filter
        mode = newFilter?.mode or "include"

        return if !filterCategory?.dataType
        return if !filterItem?.id?

        selectedFilter = {
            id: filterItem.id
            name: filterItem.name
            dataType: filterCategory.dataType
            mode: mode
            key: "#{mode}-#{filterCategory.dataType}-#{filterItem.id}"
        }

        alreadySelected = _.find(@selectedFilters, (it) -> it.key == selectedFilter.key)
        return if alreadySelected

        @selectedFilters = @selectedFilters.concat([selectedFilter])
        @.updateFilters()
        @.updateDisplayRows()

    removeFilter: (filter) ->
        return if !filter?.key

        definition = @_getDateRangeDefinitionByDataType(filter.dataType)
        if definition?
            @dateRangeFilters[definition.field] = @_emptyDateRangeFilter()

        @selectedFilters = _.filter(@selectedFilters, (it) -> it.key != filter.key)
        @_syncDateRangeSelectedFilters()
        @.updateFilters()
        @.updateDisplayRows()

    saveCustomFilter: (name) ->
        filterName = "#{name or ''}".trim()
        return if !filterName.length

        filterConfig = @._serializeSelectedFilters()

        @filterRemoteStorageService.getFilters(@scope.projectId, @customFiltersStoreName).then (userFilters) =>
            userFilters = userFilters or {}
            userFilters[filterName] = filterConfig

            @filterRemoteStorageService.storeFilters(@scope.projectId, userFilters, @customFiltersStoreName).then =>
                @.setCustomFilters(userFilters)

    selectCustomFilter: (customFilter) ->
        @filterQ = ""
        @selectedFilters = @._selectedFiltersFromConfig(customFilter?.filter)
        @.updateFilters()
        @.updateDisplayRows()

    removeCustomFilter: (customFilter) ->
        return if !customFilter?.id

        @filterRemoteStorageService.getFilters(@scope.projectId, @customFiltersStoreName).then (userFilters) =>
            userFilters = userFilters or {}
            delete userFilters[customFilter.id]

            @filterRemoteStorageService.storeFilters(@scope.projectId, userFilters, @customFiltersStoreName).then =>
                @.setCustomFilters(userFilters)

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

    toggleStatusOrder: ->
        @sortField = "status"

        if @statusSortDirection == null or @statusSortDirection == "desc"
            @statusSortDirection = "asc"
        else
            @statusSortDirection = "desc"

        @.updateDisplayRows()

    toggleEstimatedHoursOrder: ->
        @sortField = "estimated_hours"

        if @estimatedHoursSortDirection == null or @estimatedHoursSortDirection == "desc"
            @estimatedHoursSortDirection = "asc"
        else
            @estimatedHoursSortDirection = "desc"

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

        if field == "status"
            return @_directionToIconClass(@statusSortDirection)

        if field == "estimated_hours"
            return @_directionToIconClass(@estimatedHoursSortDirection)

        if @_dateSortFields.indexOf(field) != -1
            return @_directionToIconClass(@dateSortDirections[field])

        return ""

    updateFilters: ->
        rowsForCounts = @._filterRowsByQuery(@rows, @filterQ)
        rowsForCounts = @._applyDateRangeFilters(rowsForCounts)
        rowsForCounts = @._filterRowsByAdvancedSelections(rowsForCounts, @selectedFilters)

        typeCounts = _.countBy(rowsForCounts, "type")
        orderedTypes = ["epic", "userstory", "task"]

        typeContent = _.map(orderedTypes, (type) =>
            return {
                id: type
                name: @._typeFilterLabel(type)
                count: typeCounts[type] or 0
            }
        )

        tagsByName = {}
        _.each(rowsForCounts, (row) ->
            _.each(row.tags or [], (tag) ->
                name = "#{tag?[0] or ''}".trim()
                color = tag?[1] or null
                return if !name.length

                if !tagsByName[name]
                    tagsByName[name] = {
                        id: name
                        name: name
                        count: 0
                        color: color
                    }

                tagsByName[name].count += 1
                tagsByName[name].color = color if !tagsByName[name].color and color
            )
        )

        statusesById = {}
        _.each(rowsForCounts, (row) =>
            statusId = @_getStatusFilterId(row)
            return if !statusId?

            statusName = @getStatusLabel(row)
            statusColor = @getStatusColor(row)

            if !statusesById[statusId]
                statusesById[statusId] = {
                    id: statusId
                    name: statusName
                    count: 0
                    color: statusColor
                }

            statusesById[statusId].count += 1
            statusesById[statusId].color = statusColor if !statusesById[statusId].color and statusColor
        )

        assigneeCounts = {}
        _.each(rowsForCounts, (row) =>
            assigneeId = @_getAssignedToFilterId(row)
            assigneeCounts[assigneeId] = (assigneeCounts[assigneeId] or 0) + 1
        )

        assignedContent = _.map(@scope.project?.members or [], (member) =>
            memberId = "#{member?.id or ''}".trim()
            return null if !memberId.length

            memberName = member.full_name_display or member.full_name or member.username or memberId

            return {
                id: memberId
                name: memberName
                count: assigneeCounts[memberId] or 0
            }
        )

        assignedContent = _.compact(assignedContent)
        assignedContent = _.sortBy(assignedContent, (it) -> "#{it.name}".toLowerCase())
        assignedContent.unshift({
            id: "null"
            name: @translate.instant("COMMON.ASSIGNED_TO.NOT_ASSIGNED")
            count: assigneeCounts["null"] or 0
        })

        statusContent = _.sortBy(_.values(statusesById), (it) -> "#{it.name}".toLowerCase())
        tagsContent = _.sortBy(_.values(tagsByName), (it) -> it.name.toLowerCase())
        dateRangeFilterContent = _.map(@_dateRangeFilterDefinitions, (definition) =>
            rangeFilter = @dateRangeFilters[definition.field] or @_emptyDateRangeFilter()
            return {
                title: @translate.instant(definition.titleKey)
                dataType: definition.dataType
                hideEmpty: false
                totalTaggedElements: 1
                from: rangeFilter.from
                to: rangeFilter.to
                preset: rangeFilter.preset
                content: []
            }
        )

        @filters = [
            {
                title: @translate.instant("COMMON.FILTERS.CATEGORIES.TYPE")
                dataType: "type"
                hideEmpty: false
                totalTaggedElements: typeContent.length
                content: typeContent
            }
            {
                title: @translate.instant("COMMON.FILTERS.CATEGORIES.STATUS")
                dataType: "status"
                hideEmpty: false
                totalTaggedElements: statusContent.length
                content: statusContent
            }
        ].concat(dateRangeFilterContent).concat([
            {
                title: @translate.instant("COMMON.FILTERS.CATEGORIES.TAGS")
                dataType: "tags"
                hideEmpty: false
                totalTaggedElements: tagsContent.length
                content: tagsContent
            }
            {
                title: @translate.instant("COMMON.FILTERS.CATEGORIES.ASSIGNED_TO")
                dataType: "assigned_to"
                hideEmpty: false
                totalTaggedElements: assignedContent.length
                content: assignedContent
            }
        ])

    updateDisplayRows: ->
        filteredRows = @._filterRowsByQuery(@rows, @filterQ)
        filteredRows = @._applyDateRangeFilters(filteredRows)
        filteredRows = @._filterRowsByAdvancedSelections(filteredRows, @selectedFilters)

        if @sortField == "type" and @typeOrderMode != null
            @displayRows = @._orderRowsByType(filteredRows)
            return

        if @sortField == "subject" and @subjectSortDirection?
            @displayRows = @._orderRowsBySubject(@subjectSortDirection, filteredRows)
            return

        if @sortField == "status" and @statusSortDirection?
            @displayRows = @._orderRowsByStatus(@statusSortDirection, filteredRows)
            return

        if @sortField == "estimated_hours" and @estimatedHoursSortDirection?
            @displayRows = @._orderRowsByEstimatedHours(@estimatedHoursSortDirection, filteredRows)
            return

        if @_dateSortFields.indexOf(@sortField) != -1 and @dateSortDirections[@sortField]?
            @displayRows = @._orderRowsByDate(@sortField, @dateSortDirections[@sortField], filteredRows)
            return

        @displayRows = filteredRows

    setCustomFilters: (customFiltersRaw = {}) ->
        @customFilters = []

        _.forOwn customFiltersRaw, (value, key) =>
            @customFilters.push({
                id: key
                name: key
                filter: value
            })

        @customFilters = _.sortBy(@customFilters, (it) -> "#{it.name}".toLowerCase())

    _orderRowsByType: (sourceRows = @rows) ->
        orderedTypes = @_typeOrderCycles[@typeOrderMode] or @_typeOrderCycles[0]
        groupedRows = _.groupBy(sourceRows, "type")
        orderedRows = []
        includedTypes = {}

        _.each(orderedTypes, (type) ->
            includedTypes[type] = true
            orderedRows = orderedRows.concat(groupedRows[type] or [])
        )

        _.each(sourceRows, (row) ->
            return if includedTypes[row.type]
            orderedRows.push(row)
        )

        return orderedRows

    _orderRowsBySubject: (direction, sourceRows = @rows) ->
        isDescending = direction == "desc"
        orderedRows = sourceRows.slice(0)

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

    _orderRowsByStatus: (direction, sourceRows = @rows) ->
        isDescending = direction == "desc"
        orderedRows = sourceRows.slice(0)

        orderedRows.sort (a, b) =>
            statusA = "#{@getStatusLabel(a)}"
            statusB = "#{@getStatusLabel(b)}"

            comparison = statusA.localeCompare(statusB, undefined, {sensitivity: "base"})

            if comparison == 0
                comparison = @rowKey(a).localeCompare(@rowKey(b))

            if isDescending then -comparison else comparison

        return orderedRows

    _orderRowsByEstimatedHours: (direction, sourceRows = @rows) ->
        isDescending = direction == "desc"
        orderedRows = sourceRows.slice(0)

        orderedRows.sort (a, b) =>
            hoursA = @_extractEstimatedHoursValue(a.item)
            hoursB = @_extractEstimatedHoursValue(b.item)

            hasA = hoursA?
            hasB = hoursB?

            if !hasA and !hasB
                return @rowKey(a).localeCompare(@rowKey(b))

            return 1 if !hasA
            return -1 if !hasB

            comparison = hoursA - hoursB

            if comparison == 0
                comparison = @rowKey(a).localeCompare(@rowKey(b))

            if isDescending then -comparison else comparison

        return orderedRows

    _orderRowsByDate: (field, direction, sourceRows = @rows) ->
        isDescending = direction == "desc"
        orderedRows = sourceRows.slice(0)

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

    _filterRowsByAdvancedSelections: (rows, selectedFilters) ->
        return rows if !selectedFilters?.length

        selectedByDataType = _.groupBy(selectedFilters, "dataType")
        typeFilters = selectedByDataType.type or []
        statusFilters = selectedByDataType.status or []
        tagFilters = selectedByDataType.tags or []
        assignedFilters = selectedByDataType.assigned_to or []

        return _.filter(rows, (row) =>
            return false if !@_matchTypeFilters(row, typeFilters)
            return false if !@_matchStatusFilters(row, statusFilters)
            return false if !@_matchTagFilters(row, tagFilters)
            return false if !@_matchAssignedToFilters(row, assignedFilters)
            return true
        )

    _matchTypeFilters: (row, filters) ->
        return true if !filters?.length

        includeIds = _.chain(filters).filter((f) -> f.mode == "include").map((f) -> "#{f.id}".toLowerCase()).value()
        excludeIds = _.chain(filters).filter((f) -> f.mode == "exclude").map((f) -> "#{f.id}".toLowerCase()).value()

        typeValue = "#{row.type or ''}".toLowerCase()

        if includeIds.length and includeIds.indexOf(typeValue) == -1
            return false

        if excludeIds.indexOf(typeValue) != -1
            return false

        return true

    _matchStatusFilters: (row, filters) ->
        return true if !filters?.length

        includeIds = _.chain(filters).filter((f) -> f.mode == "include").map((f) -> "#{f.id}".toLowerCase()).value()
        excludeIds = _.chain(filters).filter((f) -> f.mode == "exclude").map((f) -> "#{f.id}".toLowerCase()).value()
        statusKeys = @_getStatusFilterMatchKeys(row)

        if includeIds.length and !_.some(includeIds, (id) -> statusKeys.indexOf(id) != -1)
            return false

        if _.some(excludeIds, (id) -> statusKeys.indexOf(id) != -1)
            return false

        return true

    _serializeSelectedFilters: ->
        config = {}

        _.each @selectedFilters, (filter) =>
            dataType = "#{filter?.dataType or ''}".trim()
            return if @_isDateRangeDataType(dataType)
            id = "#{filter?.id or ''}".trim()
            return if !dataType.length or !id.length

            mode = if filter.mode == "exclude" then "exclude" else "include"
            key = if mode == "exclude" then "exclude_#{dataType}" else dataType

            existingIds = []
            if _.isString(config[key])
                existingIds = _.map(config[key].split(","), (value) -> "#{value}".trim())
                existingIds = _.filter(existingIds, (value) -> value.length)

            return if existingIds.indexOf(id) != -1

            existingIds.push(id)
            config[key] = existingIds.join(",")

        _.each(@_dateRangeFilterDefinitions, (definition) =>
            rangeFilter = @dateRangeFilters[definition.field] or @_emptyDateRangeFilter()
            prefix = definition.configPrefix

            if rangeFilter?.preset?
                config["#{prefix}_preset"] = rangeFilter.preset
            else
                if rangeFilter?.from?
                    config["#{prefix}_from"] = rangeFilter.from

                if rangeFilter?.to?
                    config["#{prefix}_to"] = rangeFilter.to

            if rangeFilter?.mode == "exclude"
                config["#{prefix}_mode"] = "exclude"
        )

        return config

    _selectedFiltersFromConfig: (config) ->
        normalizedConfig = config or {}
        _.each(@_dateRangeFilterDefinitions, (definition) =>
            prefix = definition.configPrefix
            @dateRangeFilters[definition.field] = @_normalizeDateRange({
                from: normalizedConfig["#{prefix}_from"]
                to: normalizedConfig["#{prefix}_to"]
                preset: normalizedConfig["#{prefix}_preset"]
                mode: normalizedConfig["#{prefix}_mode"]
            })
        )
        availableFilterOptions = {}

        _.each @filters, (category) ->
            dataType = category?.dataType
            return if !dataType?

            availableFilterOptions[dataType] = {}
            _.each category.content or [], (it) ->
                id = "#{it?.id or ''}".trim()
                return if !id.length
                availableFilterOptions[dataType][id] = it

        selectedFilters = []
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("type", normalizedConfig.type, "include", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("type", normalizedConfig.exclude_type, "exclude", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("status", normalizedConfig.status, "include", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("status", normalizedConfig.exclude_status, "exclude", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("tags", normalizedConfig.tags, "include", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("tags", normalizedConfig.exclude_tags, "exclude", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("assigned_to", normalizedConfig.assigned_to, "include", availableFilterOptions))
        selectedFilters = selectedFilters.concat(@._deserializeFilterCategory("assigned_to", normalizedConfig.exclude_assigned_to, "exclude", availableFilterOptions))

        _.each(@_dateRangeFilterDefinitions, (definition) =>
            rangeFilter = @dateRangeFilters[definition.field] or @_emptyDateRangeFilter()
            selectedRangeFilter = @_buildDateRangeSelectedFilter(definition.dataType, rangeFilter)
            selectedFilters.push(selectedRangeFilter) if selectedRangeFilter?
        )

        return selectedFilters

    _deserializeFilterCategory: (dataType, storedValue, mode, availableFilterOptions) ->
        ids = @._toFilterIdList(storedValue)

        return _.map(ids, (id) =>
            option = availableFilterOptions[dataType]?[id]
            name = option?.name or @._fallbackFilterName(dataType, id)

            return {
                id: id
                name: name
                dataType: dataType
                mode: mode
                key: "#{mode}-#{dataType}-#{id}"
            }
        )

    _toFilterIdList: (value) ->
        if _.isArray(value)
            ids = _.map(value, (it) -> "#{it}".trim())
        else if _.isString(value)
            ids = _.map(value.split(","), (it) -> "#{it}".trim())
        else if _.isNumber(value)
            ids = ["#{value}"]
        else
            ids = []

        ids = _.filter(ids, (id) -> id.length)
        return _.uniq(ids)

    _fallbackFilterName: (dataType, id) ->
        if dataType == "assigned_to"
            return @translate.instant("COMMON.ASSIGNED_TO.NOT_ASSIGNED") if id == "null"

            member = @projectMembersById[id]
            return member.full_name_display or member.full_name or member.username or id if member

        return id

    _matchTagFilters: (row, filters) ->
        return true if !filters?.length

        includeIds = _.chain(filters).filter((f) -> f.mode == "include").map((f) -> "#{f.id}".toLowerCase()).value()
        excludeIds = _.chain(filters).filter((f) -> f.mode == "exclude").map((f) -> "#{f.id}".toLowerCase()).value()
        tagNames = _.chain(row.tags or []).map((tag) -> "#{tag?[0] or ''}".toLowerCase()).filter((name) -> name.length).value()

        if includeIds.length and !_.some(includeIds, (id) -> tagNames.indexOf(id) != -1)
            return false

        if _.some(excludeIds, (id) -> tagNames.indexOf(id) != -1)
            return false

        return true

    _matchAssignedToFilters: (row, filters) ->
        return true if !filters?.length

        includeIds = _.chain(filters).filter((f) -> f.mode == "include").map((f) -> "#{f.id}".toLowerCase()).value()
        excludeIds = _.chain(filters).filter((f) -> f.mode == "exclude").map((f) -> "#{f.id}".toLowerCase()).value()
        assignedValue = @_getAssignedToFilterId(row).toLowerCase()

        if includeIds.length and includeIds.indexOf(assignedValue) == -1
            return false

        if excludeIds.indexOf(assignedValue) != -1
            return false

        return true

    _applyDateRangeFilters: (rows) ->
        filteredRows = rows

        _.each(@_dateRangeFilterDefinitions, (definition) =>
            rangeFilter = @dateRangeFilters[definition.field] or @_emptyDateRangeFilter()
            filteredRows = @_filterRowsByDateRange(filteredRows, rangeFilter, definition.field)
        )

        return filteredRows

    _filterRowsByDateRange: (rows, range, fieldName) ->
        normalizedRange = @_normalizeDateRange(range)
        fromDate = normalizedRange.from
        toDate = normalizedRange.to
        mode = normalizedRange.mode

        return rows if !fromDate? and !toDate?

        isInRange = (row) =>
            dateFieldValue = @_normalizeDateFilterInput(row.item?[fieldName])
            return false if !dateFieldValue?
            return false if fromDate? and dateFieldValue < fromDate
            return false if toDate? and dateFieldValue > toDate
            return true

        if mode == "exclude"
            return _.filter(rows, (row) => !isInRange(row))

        return _.filter(rows, (row) => isInRange(row))

    _normalizeDateRange: (range = {}) ->
        fromDate = @_normalizeDateFilterInput(range?.from)
        toDate = @_normalizeDateFilterInput(range?.to)
        preset = "#{range?.preset or ''}".trim()
        preset = if preset.length then preset else null
        mode = if range?.mode == "exclude" then "exclude" else "include"

        if preset?
            presetRange = @_resolveDateRangePreset(preset)
            if presetRange?
                fromDate = presetRange.from
                toDate = presetRange.to
            else
                preset = null

        if fromDate? and toDate? and fromDate > toDate
            [fromDate, toDate] = [toDate, fromDate]

        return {
            from: fromDate
            to: toDate
            preset: preset
            mode: mode
        }

    _resolveDateRangePreset: (preset) ->
        baseDate = moment(@.dateRangePresetBaseDate, "YYYY-MM-DD", true)
        return null if !baseDate.isValid()

        endDate = null
        if preset == "in_one_week"
            endDate = baseDate.clone().add(1, "weeks")
        else if preset == "in_two_weeks"
            endDate = baseDate.clone().add(2, "weeks")
        else if preset == "in_one_month"
            endDate = baseDate.clone().add(1, "months")
        else if preset == "in_three_months"
            endDate = baseDate.clone().add(3, "months")
        else
            return null

        return {
            from: baseDate.format("YYYY-MM-DD")
            to: endDate.format("YYYY-MM-DD")
        }

    _syncDateRangeSelectedFilters: ->
        @selectedFilters = _.filter(@selectedFilters, (it) => !@_isDateRangeDataType(it?.dataType))

        _.each(@_dateRangeFilterDefinitions, (definition) =>
            rangeFilter = @dateRangeFilters[definition.field] or @_emptyDateRangeFilter()
            selectedRangeFilter = @_buildDateRangeSelectedFilter(definition.dataType, rangeFilter)
            @selectedFilters = @selectedFilters.concat([selectedRangeFilter]) if selectedRangeFilter?
        )

    _buildDateRangeSelectedFilter: (dataType, range) ->
        normalizedRange = @_normalizeDateRange(range)
        return null if !normalizedRange.from? and !normalizedRange.to?

        definition = @_getDateRangeDefinitionByDataType(dataType)
        return null if !definition?

        fieldLabel = @translate.instant(definition.labelKey)
        presetLabel = @_dateRangePresetLabel(normalizedRange.preset)
        fromLabel = @formatDate(normalizedRange.from)
        toLabel = @formatDate(normalizedRange.to)
        filterLabel = if presetLabel? then "#{fieldLabel}: #{presetLabel}" else "#{fieldLabel}: #{fromLabel} - #{toLabel}"
        mode = normalizedRange.mode

        return {
            id: normalizedRange.preset or "range"
            name: filterLabel
            dataType: dataType
            mode: mode
            key: "#{mode}-#{dataType}-#{normalizedRange.preset or 'range'}"
        }

    _dateRangePresetLabel: (preset) ->
        return null if !preset?
        return @translate.instant("LIGHTBOX.SET_DUE_DATE.SUGGESTIONS.IN_ONE_WEEK") if preset == "in_one_week"
        return @translate.instant("LIGHTBOX.SET_DUE_DATE.SUGGESTIONS.IN_TWO_WEEKS") if preset == "in_two_weeks"
        return @translate.instant("LIGHTBOX.SET_DUE_DATE.SUGGESTIONS.IN_ONE_MONTH") if preset == "in_one_month"
        return @translate.instant("LIGHTBOX.SET_DUE_DATE.SUGGESTIONS.IN_THREE_MONTHS") if preset == "in_three_months"
        return null

    _emptyDateRangeFilter: ->
        return {
            from: null
            to: null
            preset: null
            mode: "include"
        }

    _getDateRangeDefinitionByDataType: (dataType) ->
        return _.find(@_dateRangeFilterDefinitions, (definition) -> definition.dataType == dataType) or null

    _isDateRangeDataType: (dataType) ->
        return !!@_getDateRangeDefinitionByDataType(dataType)

    _normalizeDateFilterInput: (dateValue) ->
        if _.isDate(dateValue)
            parsedDate = moment([dateValue.getFullYear(), dateValue.getMonth(), dateValue.getDate()])
            return null if !parsedDate.isValid()
            return parsedDate.format("YYYY-MM-DD")

        value = "#{dateValue or ''}".trim()
        return null if !value.length

        parsed = moment(value, "YYYY-MM-DD", true)
        if !parsed.isValid()
            parsed = moment.parseZone(value, moment.ISO_8601, true)
        if !parsed.isValid()
            parsed = moment(value)

        return null if !parsed.isValid()
        return parsed.format("YYYY-MM-DD")

    _filterRowsByQuery: (rows, query) ->
        normalizedQuery = "#{query or ''}".trim().toLowerCase()
        return rows if !normalizedQuery.length

        queryWithoutHash = normalizedQuery.replace(/^#/, "")

        return _.filter(rows, (row) =>
            title = "#{@itemTitle(row)}".toLowerCase()
            rawRef = row.item?.ref
            ref = if rawRef? then "#{rawRef}".toLowerCase() else ""
            refWithHash = if ref.length then "##{ref}" else ""
            tags = row.tags or []

            return true if title.indexOf(normalizedQuery) != -1
            return true if refWithHash.indexOf(normalizedQuery) != -1
            return true if queryWithoutHash.length and ref.indexOf(queryWithoutHash) != -1
            return true if _.some(tags, (tag) ->
                tagName = "#{tag?[0] or ''}".toLowerCase()
                return false if !tagName.length
                return true if tagName.indexOf(normalizedQuery) != -1
                return true if queryWithoutHash.length and tagName.indexOf(queryWithoutHash) != -1
                return false
            )

            return false
        )

    _typeFilterLabel: (type) ->
        return @translate.instant("SEARCH.FILTER_EPICS") if type == "epic"
        return @translate.instant("SEARCH.FILTER_USER_STORIES") if type == "userstory"
        return @translate.instant("SEARCH.FILTER_TASKS") if type == "task"
        return type

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

    _editPermissionByRowType: (type) ->
        return "modify_epic" if type == "epic"
        return "modify_us" if type == "userstory"
        return "modify_task" if type == "task"
        return null

    canEditDate: (row) ->
        project = @scope.project
        return false if !row?.item? or !project?
        return false if project.archived_code

        permission = @_editPermissionByRowType(row.type)
        return false if !permission?

        return (project.my_permissions or []).indexOf(permission) != -1

    _hasItemField: (item, field) ->
        return false if !item? or !field?
        return true if _.has(item, field)
        attrs = item.getAttrs?()
        return _.has(attrs, field)

    _getEstimatedHoursField: (item) ->
        candidates = ["estimated_hours", "total_hours", "total_estimated_hours", "hours"]
        for field in candidates
            return field if @_hasItemField(item, field)

        return "estimated_hours"

    _normalizeEstimatedHours: (value) ->
        return null if value == null or value == undefined

        if _.isNumber(value)
            return if isNaN(value) then null else Math.max(0, value)

        normalized = "#{value}".trim()
        return null if !normalized.length

        normalized = normalized.replace(",", ".").replace(/[^0-9.-]/g, "")
        return null if !normalized.length

        parsed = parseFloat(normalized)
        return null if isNaN(parsed)
        return Math.max(0, parsed)

    _extractEstimatedHoursValue: (item) ->
        return null if !item?

        candidates = [
            item.estimated_hours
            item.total_hours
            item.total_estimated_hours
            item.hours
        ]

        for candidate in candidates
            normalized = @_normalizeEstimatedHours(candidate)
            return normalized if normalized?

        return null

    _estimatedHoursInputFromValue: (value) ->
        normalized = @_normalizeEstimatedHours(value)
        return "" if !normalized?

        if Math.round(normalized) == normalized
            return "#{Math.round(normalized)}"

        return "#{Math.round(normalized * 100) / 100}"

    _estimatedHoursInputFromItem: (item) ->
        return "" if !item?

        field = @_getEstimatedHoursField(item)
        value = @_normalizeEstimatedHours(item[field])
        value = @_extractEstimatedHoursValue(item) if !value?
        return @_estimatedHoursInputFromValue(value)

    estimatedHoursLabel: (row) ->
        hours = @_extractEstimatedHoursValue(row?.item)
        return "?" if !hours?

        normalized = if Math.round(hours) == hours then Math.round(hours) else Math.round(hours * 100) / 100
        return "#{normalized}h"

    isEditingEstimatedHours: (row) ->
        return false if !row?
        return @editingEstimatedHoursKey == @rowKey(row)

    startEstimatedHoursEdit: (row, $event) ->
        $event?.preventDefault()
        $event?.stopPropagation()

        return if !row? or !@canEditDate(row)
        return if @isSaving(row, "estimated_hours")

        @editingEstimatedHoursKey = @rowKey(row)
        row.estimatedHoursInput = @_estimatedHoursInputFromItem(row.item)
        return

    cancelEstimatedHoursEdit: (row, $event) ->
        $event?.preventDefault()
        $event?.stopPropagation()

        return if !row?

        row.estimatedHoursInput = @_estimatedHoursInputFromItem(row.item)

        if @isEditingEstimatedHours(row)
            @editingEstimatedHoursKey = null

        return

    confirmEstimatedHoursEdit: (row, $event) ->
        $event?.preventDefault()
        $event?.stopPropagation()

        return @q.reject() if !row? or !@isEditingEstimatedHours(row)

        return @saveEstimatedHours(row).then =>
            @editingEstimatedHoursKey = null
            return

    onEstimatedHoursKeydown: ($event, row) ->
        return if !$event?
        isEnter = $event.key == "Enter" or $event.keyCode == 13
        isEscape = $event.key == "Escape" or $event.keyCode == 27
        return if !isEnter and !isEscape

        $event.preventDefault()
        if isEscape
            @cancelEstimatedHoursEdit(row)
            return

        @confirmEstimatedHoursEdit(row)

    saveEstimatedHours: (row) ->
        return @q.reject() if !@canEditDate(row)
        return @q.when() if @isSaving(row, "estimated_hours")
        return @q.reject() if !row?.item?

        field = @_getEstimatedHoursField(row.item)
        normalizedOriginal = @_normalizeEstimatedHours(row.item[field])
        normalizedOriginal = @_extractEstimatedHoursValue(row.item) if !normalizedOriginal?
        normalizedNew = @_normalizeEstimatedHours(row.estimatedHoursInput)

        if normalizedOriginal == normalizedNew
            row.estimatedHoursInput = @_estimatedHoursInputFromValue(normalizedOriginal)
            return @q.when()

        row.item.setAttr(field, normalizedNew)
        @savingKey = "#{@rowKey(row)}-estimated_hours"

        return @repo.save(row.item, true, {include_schedule: true}).then =>
            @savingKey = null
            row.estimatedHoursInput = @_estimatedHoursInputFromItem(row.item)
            @confirm.notify("success")
            return
        , =>
            row.item.revert()
            @savingKey = null
            row.estimatedHoursInput = @_estimatedHoursInputFromItem(row.item)
            @confirm.notify("error")
            return @q.reject()

    itemNavKey: (row) ->
        return "project-epics-detail" if row.type == "epic"
        return "project-userstories-detail" if row.type == "userstory"
        return "project-tasks-detail" if row.type == "task"
        return null

    canOpenItem: (row) ->
        return !!(@itemNavKey(row) and row.item?.ref?)

    itemNavTitle: (row) ->
        return @itemTitle(row) if !row.item?.ref?
        return "##{row.item.ref} #{@itemTitle(row)}"

    getStatusLabel: (row) ->
        statusName = row.item?.status_extra_info?.name or row.item?.status?.name or row.item?.status_name
        return statusName if statusName?

        rawStatus = row.item?.status
        return "#{rawStatus}" if _.isString(rawStatus) or _.isNumber(rawStatus)

        return "-"

    getStatusColor: (row) ->
        return row.item?.status_extra_info?.color or row.item?.status?.color or null

    _getStatusFilterId: (row) ->
        statusLabel = @getStatusLabel(row)
        normalizedLabel = "#{statusLabel or ''}".trim()
        return normalizedLabel.toLowerCase() if normalizedLabel.length

        statusId = row.item?.status_extra_info?.id
        return "#{statusId}".toLowerCase() if statusId?

        statusObjectId = row.item?.status?.id
        return "#{statusObjectId}".toLowerCase() if statusObjectId?

        rawStatus = row.item?.status
        if _.isString(rawStatus) or _.isNumber(rawStatus)
            return "#{rawStatus}".toLowerCase()

        return null

    _getLegacyStatusFilterId: (row) ->
        statusId = row.item?.status_extra_info?.id
        return "#{row.type}:#{statusId}".toLowerCase() if statusId?

        statusObjectId = row.item?.status?.id
        return "#{row.type}:#{statusObjectId}".toLowerCase() if statusObjectId?

        rawStatus = row.item?.status
        if _.isString(rawStatus) or _.isNumber(rawStatus)
            return "#{row.type}:#{rawStatus}".toLowerCase()

        statusLabel = @getStatusLabel(row)
        normalizedLabel = "#{statusLabel or ''}".trim()
        return "#{row.type}:#{normalizedLabel}".toLowerCase() if normalizedLabel.length

        return null

    _getStatusFilterMatchKeys: (row) ->
        keys = []
        statusId = @_getStatusFilterId(row)
        legacyStatusId = @_getLegacyStatusFilterId(row)

        keys.push(statusId) if statusId?
        keys.push(legacyStatusId) if legacyStatusId?

        return _.uniq(keys)

    getStatusStyle: (row) ->
        color = @getStatusColor(row)
        return {} if !color
        return {"color": color}

    _getAssignedToFilterId: (row) ->
        assignedTo = row.item?.assigned_to
        return "#{assignedTo}" if assignedTo?
        return "null"

    getAssignedToMember: (row) ->
        member = row.item?.assigned_to_extra_info
        return member if member

        assignedTo = row.item?.assigned_to
        return null if !assignedTo?

        return @projectMembersById["#{assignedTo}"] or null

    getAssignedToName: (row) ->
        member = @getAssignedToMember(row)
        if member
            return member.full_name_display or member.full_name or member.username or @translate.instant("COMMON.ASSIGNED_TO.NOT_ASSIGNED")

        return @translate.instant("COMMON.ASSIGNED_TO.NOT_ASSIGNED")

    itemTitle: (row) ->
        return row.item.subject or row.item.name or "-"

    formatDate: (dateValue) ->
        return "?" if !dateValue

        parsed = moment(dateValue)
        return dateValue if !parsed.isValid()

        return parsed.format("DD MMM YYYY")

    getDateValue: (row, field) ->
        return row.item[field]

    isSaving: (row, field) ->
        return @savingKey == "#{@rowKey(row)}-#{field}"

    openDateLightbox: (row, field) ->
        return if !@canEditDate(row)
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
        return @q.reject() if !@canEditDate(row)

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
