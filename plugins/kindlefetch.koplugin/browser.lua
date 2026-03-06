local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Screen = Device.screen
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local KindleFetchBrowser = WidgetContainer:extend{
    name = "kindlefetch_browser",
}

function KindleFetchBrowser:isShown()
    return self.menu_container ~= nil
end

function KindleFetchBrowser:show(initial_tab)
    if self.menu_container then
        self:refresh()
        return
    end

    self.menu_container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Screen:getSize(),
    }
    self:buildMenu(initial_tab)
    UIManager:show(self.menu_container)
end

function KindleFetchBrowser:buildMenu(initial_tab)
    local tab_item_table = self.manager:getBrowserTabs()
    local full_height = Screen:getHeight()

    local menu_widget = TouchMenu:new{
        width = Screen:getWidth(),
        max_per_page_default = 9999,
        last_index = initial_tab or self.last_tab_index or 1,
        tab_item_table = tab_item_table,
        show_parent = self.menu_container,
    }

    local original_update_items = menu_widget.updateItems
    menu_widget.updateItems = function(widget, ...)
        local original_item_table = widget.item_table
        local padded_item_table
        if original_item_table and #original_item_table > 0 then
            local perpage = math.min(widget.max_per_page, original_item_table.max_per_page or widget.max_per_page_default)
            local remainder = #original_item_table % perpage
            local filler = remainder == 0 and 0 or (perpage - remainder)
            if filler > 0 then
                padded_item_table = {}
                for i, item in ipairs(original_item_table) do
                    padded_item_table[i] = item
                end
                padded_item_table.max_per_page = original_item_table.max_per_page
                for _ = 1, filler do
                    table.insert(padded_item_table, {
                        text = " ",
                        enabled = false,
                    })
                end
                widget.item_table = padded_item_table
            end
        end

        original_update_items(widget, ...)
        widget.item_table = original_item_table

        if widget.menu_frame then
            widget.menu_frame.height = full_height
        end
        widget.dimen.h = full_height
    end

    if menu_widget.menu_frame then
        menu_widget.menu_frame.height = full_height
    end
    menu_widget.dimen.h = full_height

    menu_widget.close_callback = function()
        self:onCloseMenu()
    end

    self.menu_container[1] = menu_widget
    self.menu_widget = menu_widget
    self.menu_widget:updateItems(1)
end

function KindleFetchBrowser:onCloseMenu()
    if not self.menu_container then
        return
    end

    if self.menu_widget and self.menu_widget.last_index then
        self.last_tab_index = self.menu_widget.last_index
    end

    local widget = self.menu_container
    self.menu_widget = nil
    self.menu_container = nil
    self.manager:onBrowserClosed()
    UIManager:close(widget)
end

function KindleFetchBrowser:close()
    self:onCloseMenu()
end

function KindleFetchBrowser:refresh(force_tab_index)
    if not self.menu_widget then
        return
    end
    self.menu_widget.tab_item_table = self.manager:getBrowserTabs()
    local tab_index = force_tab_index
        or self.menu_widget.cur_tab
        or self.menu_widget.last_index
        or 1
    self.menu_widget:switchMenuTab(tab_index)
end

return KindleFetchBrowser
