###
# This source code is licensed under the terms of the
# GNU Affero General Public License found in the LICENSE file in
# the root directory of this source tree.
#
# Copyright (c) 2021-present Kaleidos INC
###

class FilterController
    @.$inject = [
        '$translate',
    ]

    @.activeCustomFilter = null
    @.repeatedFilterError = false
    @.lengthZeroError = false

    constructor: (@translate) ->
        @.opened = null
        @.prettyDateFormat = @translate.instant("COMMON.PICKERDATE.FORMAT")
        @.filterModeOptions = ["include", "exclude"]
        @.filterModeLabels = {
            "include": @translate.instant("COMMON.FILTERS.ADVANCED_FILTERS.INCLUDE"),
            "exclude": @translate.instant("COMMON.FILTERS.ADVANCED_FILTERS.EXCLUDE"),
        }
        @.filterMode = 'include'
        @.customFilterForm = false
        @.customFilterName = ''

        @.$onChanges = (changes) ->
            if changes.selectedFilters
                @.getIncludedFilters()
                @.getExcludedFilters()
            if changes.filters
                @.syncDateRangeInputs()

        @.includedFilters = @.getIncludedFilters()
        @.excludedFilters = @.getExcludedFilters()
        @.syncDateRangeInputs()


    toggleFilterCategory: (filterName) ->
        if @.opened == filterName
            @.opened = null
        else
            @.opened = filterName

    isOpen: (filterName) ->
        return @.opened == filterName

    openCustomFilter: () ->
        @.customFilterForm = true
        @.lengthZeroError = false
        @.repeatedFilterError = false

    saveCustomFilter: () ->
        if @.customFilterName.length > 0 && !@.customFilters.find((filter) => filter.name == @.customFilterName)
            @.lengthZeroError = false
            @.repeatedFilterError = false
            @.onSaveCustomFilter({name: @.customFilterName})
            @.customFilterForm = false
            @.opened = 'custom-filter'
            @.customFilterName = ''

        if @.customFilterName.length == 0
            @.lengthZeroError = true
        else
            @.lengthZeroError = false

        if !@.customFilters.find((filter) => filter.name == @.customFilterName)
            @.repeatedFilterError = false
        else
            @.repeatedFilterError = true

    unselectFilter: (filter) ->
        @.activeCustomFilter = null
        @.onRemoveFilter({filter: filter})

    selectFilter: (filterCategory, filter) ->
        filter = {
            category: filterCategory
            filter: filter
            mode: @.filterMode
        }
        @.activeCustomFilter = null
        @.onAddFilter({filter: filter})

    removeCustomFilter: (filter) ->
        @.activeCustomFilter = null
        @.onRemoveCustomFilter({filter: filter})

    selectCustomFilter: (filter) ->
        @.activeCustomFilter = filter.id
        @.onSelectCustomFilter({filter: filter})

    applyDateRange: (filterCategory) ->
        return if !@.onSetDateRange

        from = @.normalizeDateRangeInput(filterCategory?.fromInput)
        to = @.normalizeDateRangeInput(filterCategory?.toInput)

        if from? and to? and from > to
            [from, to] = [to, from]

        filterCategory.fromInput = @.toPickerInputValue(from)
        filterCategory.toInput = @.toPickerInputValue(to)
        filterCategory.preset = null

        @.activeCustomFilter = null
        @.onSetDateRange({range: {from: from, to: to, preset: null, mode: @.filterMode}})

    clearDateRange: (filterCategory) ->
        filterCategory.fromInput = ""
        filterCategory.toInput = ""

        @.activeCustomFilter = null

        if @.onClearDateRange
            @.onClearDateRange()
        else if @.onSetDateRange
            @.onSetDateRange({range: {from: null, to: null}})

    applyDateRangePreset: (filterCategory, preset) ->
        return if !@.onSetDateRange
        return if !preset?

        filterCategory.preset = preset
        @.activeCustomFilter = null
        @.onSetDateRange({range: {preset: preset, mode: @.filterMode}})

    getIncludedFilters: () ->
        @.includedFilters = _.filter @.selectedFilters, (it) ->
            return it.mode == 'include'

    getExcludedFilters: () ->
        @.excludedFilters = _.filter @.selectedFilters, (it) ->
            return it.mode == 'exclude'

    isFilterSelected: (filterCategory, filter) ->
        return !!_.find @.selectedFilters, (it) ->
            return filter.id == it.id && filterCategory.dataType == it.dataType

    syncDateRangeInputs: () ->
        _.each @.filters or [], (filterCategory) =>
            return if filterCategory?.dataType != "due_date_range"

            if filterCategory?.preset?
                filterCategory.fromInput = ""
                filterCategory.toInput = ""
                return

            filterCategory.fromInput = @.toPickerInputValue(filterCategory.from)
            filterCategory.toInput = @.toPickerInputValue(filterCategory.to)

    normalizeDateRangeInput: (dateValue) ->
        return null if !dateValue?

        parsed = null
        if _.isDate(dateValue)
            parsed = moment([dateValue.getFullYear(), dateValue.getMonth(), dateValue.getDate()])
        else
            value = "#{dateValue or ''}".trim()
            return null if !value.length

            parsed = moment(value, @prettyDateFormat, true)
            if !parsed.isValid()
                parsed = moment(value, "YYYY-MM-DD", true)
            if !parsed.isValid()
                parsed = moment.parseZone(value, moment.ISO_8601, true)
            if !parsed.isValid()
                parsed = moment(value)

        return null if !parsed?.isValid()

        return parsed.format("YYYY-MM-DD")

    toPickerInputValue: (dateValue) ->
        normalized = @.normalizeDateRangeInput(dateValue)
        return "" if !normalized?

        parsed = moment(normalized, "YYYY-MM-DD", true)
        return normalized if !parsed.isValid()

        return parsed.format(@prettyDateFormat)

    hasAnySelectedFilter: () ->
        return true if (@selectedFilters or []).length > 0

        return _.some(@filters or [], (filterCategory) =>
            return false if filterCategory?.dataType != "due_date_range"
            fromValue = @.normalizeDateRangeInput(filterCategory.fromInput or filterCategory.from)
            toValue = @.normalizeDateRangeInput(filterCategory.toInput or filterCategory.to)
            return !!(fromValue or toValue)
        )

angular.module('taigaComponents').controller('Filter', FilterController)
