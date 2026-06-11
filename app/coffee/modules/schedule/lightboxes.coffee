###
# This source code is licensed under the terms of the
# GNU Affero General Public License found in the LICENSE file in
# the root directory of this source tree.
#
# Copyright (c) 2021-present Kaleidos INC
###

module = angular.module("taigaSchedule")

ScheduleSetDateDirective = (lightboxService, $loading, $translate, $confirm) ->
    link = ($scope, $el, attrs) ->
        prettyDate = $translate.instant("COMMON.PICKERDATE.FORMAT")
        fieldName = $scope.fieldName or "due_date"
        fieldLabel = ($scope.fieldLabel or fieldName).replace(/_/g, " ")
        isDueDateField = fieldName == "due_date"

        $scope.lightboxTitle = if $scope.lightboxTitle? then $scope.lightboxTitle else if isDueDateField then $translate.instant("LIGHTBOX.SET_DUE_DATE.TITLE") else "Set #{fieldLabel}"
        $scope.datePlaceholder = $translate.instant("LIGHTBOX.SET_DUE_DATE.PLACEHOLDER_DUE_DATE")
        $scope.showSuggestions = true
        $scope.showDueDateReason = isDueDateField
        $scope.deleteDateTitle = if isDueDateField then $translate.instant("LIGHTBOX.SET_DUE_DATE.TITLE_ACTION_DELETE_DUE_DATE") else $translate.instant("COMMON.DELETE")

        lightboxService.open($el)

        if $scope.object?.due_date
            $scope.new_due_date = moment($scope.object.due_date).format(prettyDate)

        parsePickerDate = (rawDate) ->
            return null if !rawDate

            parsed = moment(rawDate, prettyDate, true)
            return null if !parsed.isValid()
            return parsed.format("YYYY-MM-DD")

        persistDate = (newDateValue, currentLoading = null) ->
            previousDateValue = $scope.object?.due_date
            $scope.object.due_date = newDateValue if $scope.object?

            closeLightbox = ->
                currentLoading?.finish()
                lightboxService.close($el)

            if !_.isFunction($scope.onSave)
                $scope.$apply()
                closeLightbox()
                return

            savePromise = $scope.onSave(newDateValue, previousDateValue)

            if savePromise?.then
                savePromise.then ->
                    $confirm.notify("success")
                , ->
                    $scope.object.due_date = previousDateValue if $scope.object?
                    $confirm.notify("error")

                savePromise.finally ->
                    closeLightbox()
            else
                closeLightbox()

        $el.on "click", ".suggestion", (event) ->
            target = angular.element(event.currentTarget)
            quantity = target.data("quantity")
            unit = target.data("unit")
            value = moment().add(quantity, unit).format(prettyDate)
            $el.find(".due-date").val(value)

        save = ->
            currentLoading = $loading()
                .target($el.find(".submit-button"))
                .start()

            newDateValue = parsePickerDate($el.find(".due-date").val())
            persistDate(newDateValue, currentLoading)

        $el.on "click", ".submit-button", (event) ->
            event.preventDefault()
            save()

        remove = ->
            if !isDueDateField
                $el.find(".due-date").val(null)
                $scope.object.due_date_reason = null if $scope.object?
                persistDate(null)
                return

            title = $translate.instant("LIGHTBOX.DELETE_DUE_DATE.TITLE")
            subtitle = $translate.instant("LIGHTBOX.DELETE_DUE_DATE.SUBTITLE")
            message = moment($scope.object?.due_date).format(prettyDate)

            $confirm.askOnDelete(title, message, subtitle).then (askResponse) ->
                askResponse.finish()
                $el.find(".due-date").val(null)
                $scope.object.due_date_reason = null if $scope.object?
                persistDate(null)

        $el.on "click", ".delete-due-date", (event) ->
            event.preventDefault()
            remove()

        $scope.$on "$destroy", ->
            $el.off()

    return {
        templateUrl: "schedule/lightbox-set-date.html",
        link: link,
        scope: true
    }

module.directive("tgScheduleLbSetDate", ["lightboxService", "$tgLoading", "$translate", "$tgConfirm", ScheduleSetDateDirective])
