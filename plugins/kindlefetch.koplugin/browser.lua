local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local KindleFetchBrowser = WidgetContainer:extend{
    name = "kindlefetch_browser",
}

function KindleFetchBrowser:isShown()
    return self.booklist ~= nil
end

function KindleFetchBrowser:show()
    if self.booklist then
        self:refresh()
        return
    end

    self.booklist = BookList:new{
        title = self.manager:getBrowserTitle(),
        item_table = self.manager:getBrowserItemTable(),
        title_bar_fm_style = true,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self:showMenu()
        end,
        onMenuSelect = function(_, item)
            self.manager:onBrowserItemSelected(item)
        end,
        close_callback = function()
            self:onBookListClose()
        end,
    }
    UIManager:show(self.booklist)
end

function KindleFetchBrowser:onBookListClose()
    if not self.booklist then
        return
    end

    local widget = self.booklist
    self.booklist = nil
    UIManager:close(widget)
    self.manager:onBrowserClosed()
end

function KindleFetchBrowser:close()
    self:onBookListClose()
end

function KindleFetchBrowser:refresh()
    if not self.booklist then
        return
    end
    self.booklist:switchItemTable(self.manager:getBrowserTitle(), self.manager:getBrowserItemTable())
end

function KindleFetchBrowser:showMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("KindleFetch"),
        buttons = {
            {
                {
                    text = _("New search"),
                    callback = function()
                        UIManager:close(dialog)
                        self.manager:showSearchDialog(self.manager.last_query)
                    end,
                },
                {
                    text = _("Default source"),
                    callback = function()
                        UIManager:close(dialog)
                        self.manager:showDefaultSourceDialog()
                    end,
                },
            },
            {
                {
                    text = _("Search filter"),
                    callback = function()
                        UIManager:close(dialog)
                        self.manager:showSourceFilterDialog()
                    end,
                },
                {
                    text = _("Set root path"),
                    callback = function()
                        UIManager:close(dialog)
                        self.manager:showSetRootDialog()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                        self:close()
                    end,
                },
            },
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.booklist.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

return KindleFetchBrowser
