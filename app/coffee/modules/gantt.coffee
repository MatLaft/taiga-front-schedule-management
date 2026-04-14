###
# This source code is licensed under the terms of the
# GNU Affero General Public License found in the LICENSE file in
# the root directory of this source tree.
#
# Copyright (c) 2021-present Kaleidos INC
###

module = angular.module("taigaGantt", [])

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

        barsSvg = root.querySelector(".gantt-bars-svg")
        bars = if barsSvg? then Array.from(root.querySelectorAll(".gantt-bar[data-gantt-row-id]")) else []

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
            return if !barsSvg?

            totalDays = parseFloat(barsSvg.getAttribute("data-total-days") or "0") or 0
            totalDays = Math.max(1, totalDays)
            barsSvg.setAttribute("viewBox", "0 0 #{totalDays} #{Math.max(1, visibleRowsCount)}")

            bars.forEach (bar) ->
                rowId = bar.getAttribute("data-gantt-row-id")
                rowIndex = visibleRowMap[rowId]

                if rowIndex == undefined
                    bar.classList.add("is-hidden")
                    return

                startDay = parseFloat(bar.getAttribute("data-start-day") or "1") or 1
                endDay = parseFloat(bar.getAttribute("data-end-day") or startDay) or startDay
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

            visibleRows = visibleRows.length
            visibleRows = Math.max(visibleRows, 1)
            root.style.setProperty("--gantt-visible-rows", "#{visibleRows}")

        onChange = (event) ->
            target = event.target
            return if !target?.classList?.contains("gantt-node-trigger")
            updateVisibleRows()

        leftPanel.addEventListener("change", onChange)
        $scope.$evalAsync(updateVisibleRows)

        $scope.$on "$destroy", ->
            leftPanel.removeEventListener("change", onChange)

    return {link: link}

module.directive("tgGanttSyncRows", [GanttSyncRowsDirective])
