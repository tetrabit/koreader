local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local SETTINGS_KEYS = {
    root_override = "kindlefetch_root_override",
    default_source = "kindlefetch_default_source",
    source_filter = "kindlefetch_source_filter",
    last_query = "kindlefetch_last_query",
}

local ROOT_CANDIDATES = {
    "/mnt/us/extensions/kindlefetch",
    "/mnt/us/extensions/KindleFetch",
    "/home/nullvoid/scratch/KindleFetch/kindlefetch",
    "/home/nullvoid/scratch/KindleFetch",
}

local SOURCE_LABELS = {
    ask = _("Ask every time"),
    lgli = _("Library Genesis"),
    zlib = _("Z-Library"),
}

local FILTER_LABELS = {
    all = _("All sources"),
    lgli = _("Library Genesis only"),
    zlib = _("Z-Library only"),
}

local KindleFetch = WidgetContainer:extend{
    name = "kindlefetch",
    is_doc_only = false,
}

function KindleFetch:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindlefetch_search", {
        category = "none",
        event = "KindleFetchSearch",
        title = _("KindleFetch search"),
        reader = true,
        filemanager = true,
    })
    Dispatcher:registerAction("kindlefetch_set_root", {
        category = "none",
        event = "KindleFetchSetRoot",
        title = _("Set KindleFetch root"),
        reader = true,
        filemanager = true,
    })
end

function KindleFetch:init()
    self:loadSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KindleFetch:loadSettings()
    self.root_override = G_reader_settings:readSetting(SETTINGS_KEYS.root_override)
    self.default_source = G_reader_settings:readSetting(SETTINGS_KEYS.default_source, "ask")
    if not SOURCE_LABELS[self.default_source] then
        self.default_source = "ask"
    end
    self.source_filter = G_reader_settings:readSetting(SETTINGS_KEYS.source_filter, "all")
    if not FILTER_LABELS[self.source_filter] then
        self.source_filter = "all"
    end
    self.last_query = G_reader_settings:readSetting(SETTINGS_KEYS.last_query, "")
end

function KindleFetch:addToMainMenu(menu_items)
    menu_items.kindlefetch = {
        text = _("KindleFetch"),
        sorting_hint = "tools",
        callback = function()
            self:onKindleFetchSearch()
        end,
    }
end

function KindleFetch:getDefaultSourceSubmenu()
    return {
        {
            text = SOURCE_LABELS.ask,
            checked_func = function()
                return self.default_source == "ask"
            end,
            callback = function()
                self:setDefaultSource("ask")
            end,
        },
        {
            text = SOURCE_LABELS.lgli,
            checked_func = function()
                return self.default_source == "lgli"
            end,
            callback = function()
                self:setDefaultSource("lgli")
            end,
        },
        {
            text = SOURCE_LABELS.zlib,
            checked_func = function()
                return self.default_source == "zlib"
            end,
            callback = function()
                self:setDefaultSource("zlib")
            end,
        },
    }
end

function KindleFetch:getSourceFilterSubmenu()
    return {
        {
            text = FILTER_LABELS.all,
            checked_func = function()
                return self.source_filter == "all"
            end,
            callback = function()
                self:setSourceFilter("all")
            end,
        },
        {
            text = FILTER_LABELS.lgli,
            checked_func = function()
                return self.source_filter == "lgli"
            end,
            callback = function()
                self:setSourceFilter("lgli")
            end,
        },
        {
            text = FILTER_LABELS.zlib,
            checked_func = function()
                return self.source_filter == "zlib"
            end,
            callback = function()
                self:setSourceFilter("zlib")
            end,
        },
    }
end

function KindleFetch:setDefaultSource(source)
    self.default_source = source
    G_reader_settings:saveSetting(SETTINGS_KEYS.default_source, source)
end

function KindleFetch:setSourceFilter(filter)
    self.source_filter = filter
    G_reader_settings:saveSetting(SETTINGS_KEYS.source_filter, filter)
end

function KindleFetch:onKindleFetchSearch()
    self:openBrowser()
    return true
end

function KindleFetch:onKindleFetchSetRoot()
    self:showSetRootDialog()
    return true
end

function KindleFetch:isKindleFetchRoot(path)
    return path
        and lfs.attributes(path .. "/bin/kindlefetch.sh", "mode") == "file"
end

function KindleFetch:normalizeRootPath(path)
    if type(path) ~= "string" then
        return nil
    end
    local trimmed = util.trim(path)
    if trimmed == "" then
        return nil
    end
    local real = ffiUtil.realpath(trimmed) or trimmed
    if self:isKindleFetchRoot(real) then
        return real
    end
    local nested = real .. "/kindlefetch"
    if self:isKindleFetchRoot(nested) then
        return nested
    end
    return nil
end

function KindleFetch:getKindleFetchRoot()
    local configured = self:normalizeRootPath(self.root_override)
    if configured then
        return configured
    end
    for _, candidate in ipairs(ROOT_CANDIDATES) do
        local normalized = self:normalizeRootPath(candidate)
        if normalized then
            return normalized
        end
    end
    return nil
end

function KindleFetch:openBrowser()
    if self.browser and self.browser:isShown() then
        self.browser:refresh()
        return true
    end

    local Browser = require("browser")
    self.browser = Browser:new{
        manager = self,
    }
    self.browser:show()
    return true
end

function KindleFetch:refreshBrowser()
    if self.browser and self.browser:isShown() then
        self.browser:refresh()
    end
end

function KindleFetch:onBrowserClosed()
    self.browser = nil
end

function KindleFetch:onClose()
    if self.browser and self.browser:isShown() then
        self.browser:close()
    end
end

function KindleFetch:onCloseWidget()
    if self.browser and self.browser:isShown() then
        self.browser:close()
    end
end

function KindleFetch:getBrowserTitle()
    if self.search_state then
        return T(
            _("KindleFetch: %1 (page %2/%3)"),
            self.search_state.query,
            self.search_state.page,
            self.search_state.last_page
        )
    end
    return _("KindleFetch")
end

function KindleFetch:getBrowserItemTable()
    local items = {}
    local state = self.search_state
    local root = self:getKindleFetchRoot()

    if state then
        table.insert(items, {
            text = _("New search"),
            mandatory = T(_("Current: %1"), state.query),
            action = "search",
        })
        if state.page > 1 then
            table.insert(items, {
                text = _("Previous page"),
                action = "page_prev",
            })
        end
        if state.page < state.last_page then
            table.insert(items, {
                text = _("Next page"),
                action = "page_next",
            })
        end
    else
        table.insert(items, {
            text = _("Start new search"),
            action = "search",
        })
    end

    table.insert(items, {
        text = T(_("Default source: %1"), SOURCE_LABELS[self.default_source]),
        action = "default_source",
    })
    table.insert(items, {
        text = T(_("Search filter: %1"), FILTER_LABELS[self.source_filter]),
        action = "source_filter",
    })
    table.insert(items, {
        text = _("Set KindleFetch root path"),
        action = "set_root",
    })
    table.insert(items, {
        text = root and T(_("Detected root: %1"), BD.dirpath(root)) or _("Detected root: not found"),
        enabled = false,
    })

    if not state then
        return items
    end

    table.insert(items, {
        text = T(_("Results (%1)"), #state.results),
        enabled = false,
    })
    if #state.results == 0 then
        table.insert(items, {
            text = _("No results on this page."),
            enabled = false,
        })
        return items
    end

    for i, book in ipairs(state.results) do
        local title = util.trim(book.title or "")
        local author = util.trim(book.author or "")
        local format = util.trim(book.format or "")
        if title == "" then
            title = _("Untitled")
        end
        if author == "" then
            author = _("Unknown author")
        end
        if format == "" then
            format = "?"
        end
        table.insert(items, {
            text = title,
            mandatory = T("%1 | %2", author, format),
            action = "result",
            result_index = i,
            book = book,
        })
    end

    return items
end

function KindleFetch:onBrowserItemSelected(item)
    if not item or not item.action then
        return
    end

    if item.action == "search" then
        self:showSearchDialog(self.last_query)
        return
    end
    if item.action == "page_prev" and self.search_state then
        self:startSearch(self.search_state.query, self.search_state.page - 1)
        return
    end
    if item.action == "page_next" and self.search_state then
        self:startSearch(self.search_state.query, self.search_state.page + 1)
        return
    end
    if item.action == "default_source" then
        self:showDefaultSourceDialog()
        return
    end
    if item.action == "source_filter" then
        self:showSourceFilterDialog()
        return
    end
    if item.action == "set_root" then
        self:showSetRootDialog()
        return
    end
    if item.action == "result" and item.result_index and item.book then
        self:onSelectResult(item.result_index, item.book)
        return
    end
end

function KindleFetch:showDefaultSourceDialog()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Default source"),
        buttons = {
            {
                {
                    text = SOURCE_LABELS.ask,
                    callback = function()
                        UIManager:close(dialog)
                        self:setDefaultSource("ask")
                        self:refreshBrowser()
                    end,
                },
            },
            {
                {
                    text = SOURCE_LABELS.lgli,
                    callback = function()
                        UIManager:close(dialog)
                        self:setDefaultSource("lgli")
                        self:refreshBrowser()
                    end,
                },
            },
            {
                {
                    text = SOURCE_LABELS.zlib,
                    callback = function()
                        UIManager:close(dialog)
                        self:setDefaultSource("zlib")
                        self:refreshBrowser()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
        width_factor = 0.7,
    }
    UIManager:show(dialog)
end

function KindleFetch:showSourceFilterDialog()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Search filter"),
        buttons = {
            {
                {
                    text = FILTER_LABELS.all,
                    callback = function()
                        UIManager:close(dialog)
                        self:setSourceFilter("all")
                        self:refreshBrowser()
                    end,
                },
            },
            {
                {
                    text = FILTER_LABELS.lgli,
                    callback = function()
                        UIManager:close(dialog)
                        self:setSourceFilter("lgli")
                        self:refreshBrowser()
                    end,
                },
            },
            {
                {
                    text = FILTER_LABELS.zlib,
                    callback = function()
                        UIManager:close(dialog)
                        self:setSourceFilter("zlib")
                        self:refreshBrowser()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
        width_factor = 0.7,
    }
    UIManager:show(dialog)
end

function KindleFetch:getBridgePath()
    if self.path then
        return self.path .. "/kf_bridge.sh"
    end
    return "plugins/kindlefetch.koplugin/kf_bridge.sh"
end

function KindleFetch:buildBridgeCommand(args)
    local cmd_args = { self:getBridgePath(), }
    local root = self:getKindleFetchRoot()
    if root then
        table.insert(cmd_args, "--root")
        table.insert(cmd_args, root)
    end
    for _, arg in ipairs(args) do
        table.insert(cmd_args, arg)
    end
    return "sh " .. util.shell_escape(cmd_args) .. " 2>&1; rc=$?; printf '\\n__KF_RC__=%s\\n' \"$rc\""
end

function KindleFetch:runBridgeCommand(args, progress_text)
    local Trapper = require("ui/trapper")
    if lfs.attributes(self:getBridgePath(), "mode") ~= "file" then
        return false, _("KindleFetch bridge script is missing.")
    end
    local completed, output = Trapper:dismissablePopen(
        self:buildBridgeCommand(args),
        progress_text or _("Working... (tap to cancel)")
    )
    Trapper:reset()
    if not completed then
        return false, _("Operation canceled.")
    end

    output = output or ""
    local rc = tonumber(output:match("__KF_RC__=(%d+)")) or 1
    output = output:gsub("\n__KF_RC__=%d+\n?$", "\n")
    if rc ~= 0 then
        return false, output
    end
    return true, output
end

function KindleFetch:getMarker(output, key)
    return output and output:match("__KF_" .. key .. "__=([^\n\r]+)")
end

function KindleFetch:cleanOutput(output)
    if not output then
        return _("No details.")
    end
    local cleaned = output:gsub("__KF_[A-Z_]+__=[^\n\r]*[\n\r]*", "")
    cleaned = util.trim(cleaned)
    if cleaned == "" then
        return _("No details.")
    end
    if #cleaned > 1200 then
        cleaned = cleaned:sub(1, 1200) .. "\n..."
    end
    return cleaned
end

function KindleFetch:showFailure(title, output)
    UIManager:show(InfoMessage:new{
        text = T(_("%1\n\n%2"), title, self:cleanOutput(output)),
        show_icon = true,
    })
end

function KindleFetch:showSearchDialog(default_query)
    local dialog
    dialog = InputDialog:new{
        title = _("KindleFetch search"),
        description = _("Search Anna's Archive through KindleFetch and download EPUB/PDF files."),
        input = default_query or "",
        input_hint = _("Enter title or author"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = util.trim(dialog:getInputText() or "")
                        if query == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Search query cannot be empty."),
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:startSearch(query, 1)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KindleFetch:startSearch(query, page)
    local Trapper = require("ui/trapper")
    self.last_query = query
    G_reader_settings:saveSetting(SETTINGS_KEYS.last_query, query)

    Trapper:wrap(function()
        local args = {
            "search",
            "--query", query,
            "--page", tostring(page or 1),
        }
        if self.source_filter ~= "all" then
            table.insert(args, "--source")
            table.insert(args, self.source_filter)
        end

        local ok, output = self:runBridgeCommand(args, _("Searching KindleFetch... (tap to cancel)"))
        if not ok then
            self:showFailure(_("Search failed."), output)
            return
        end

        local current_page = tonumber(self:getMarker(output, "PAGE")) or (page or 1)
        local last_page = tonumber(self:getMarker(output, "LAST_PAGE")) or current_page
        local results_file = self:getMarker(output, "RESULTS_FILE") or "/tmp/search_results.json"

        local results, err = self:readSearchResults(results_file)
        if not results then
            self:showFailure(_("Could not parse search results."), err)
            return
        end

        self.search_state = {
            query = query,
            page = current_page,
            last_page = last_page,
            results = results,
        }
        self:showResultsDialog()
    end)
end

function KindleFetch:readSearchResults(path)
    local fd = io.open(path, "rb")
    if not fd then
        return nil, T(_("Results file not found: %1"), path)
    end

    local content = fd:read("*all") or ""
    fd:close()

    local ok, decoded = pcall(rapidjson.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil, _("Invalid JSON in results file.")
    end
    return decoded
end

function KindleFetch:showResultsDialog()
    self:openBrowser()
    self:refreshBrowser()
end

function KindleFetch:getAvailableSources(book)
    local description = string.lower(book.description or "")
    local sources = {}
    if description:find("lgli", 1, true) then
        table.insert(sources, "lgli")
    end
    if description:find("zlib", 1, true) then
        table.insert(sources, "zlib")
    end
    return sources
end

function KindleFetch:onSelectResult(index, book)
    local available = self:getAvailableSources(book)
    local source = self.default_source

    if source ~= "ask" then
        if #available > 0 then
            local supported = false
            for _, candidate in ipairs(available) do
                if candidate == source then
                    supported = true
                    break
                end
            end
            if not supported then
                source = available[1]
            end
        end
        self:confirmDownload(index, book, source)
        return
    end

    if #available == 1 then
        self:confirmDownload(index, book, available[1])
        return
    end

    self:showSourcePicker(index, book, available)
end

function KindleFetch:showSourcePicker(index, book, available)
    local dialog
    local sources = available
    if #sources == 0 then
        sources = { "lgli", "zlib", }
    end

    local buttons = {}
    for _, source in ipairs(sources) do
        local source_label = SOURCE_LABELS[source] or source
        table.insert(buttons, {
            {
                text = T(_("Download via %1"), source_label),
                callback = function()
                    UIManager:close(dialog)
                    self:confirmDownload(index, book, source)
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Back to results"),
            callback = function()
                UIManager:close(dialog)
                self:showResultsDialog()
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Choose download source"),
        buttons = buttons,
        width_factor = 0.8,
    }
    UIManager:show(dialog)
end

function KindleFetch:confirmDownload(index, book, source)
    local title = util.trim(book.title or "")
    if title == "" then
        title = _("Untitled")
    end

    UIManager:show(ConfirmBox:new{
        text = T(
            _("Download this book?\n\nTitle:\n%1\n\nSource:\n%2"),
            title,
            SOURCE_LABELS[source] or source
        ),
        ok_text = _("Download"),
        ok_callback = function()
            self:downloadBook(index, source)
        end,
        cancel_callback = function()
            self:showResultsDialog()
        end,
    })
end

function KindleFetch:downloadBook(index, source)
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local ok, output = self:runBridgeCommand({
            "download",
            "--index", tostring(index),
            "--source", source,
        }, _("Downloading... (tap to cancel)"))

        if not ok then
            self:showFailure(_("Download failed."), output)
            self:showResultsDialog()
            return
        end

        local saved_path = self:getMarker(output, "SAVED_PATH")
        if not saved_path or util.trim(saved_path) == "" then
            saved_path = output:match("Saved to:%s*([^\n\r]+)")
        end
        saved_path = saved_path and util.trim(saved_path) or nil

        if saved_path and lfs.attributes(saved_path, "mode") == "file" then
            UIManager:nextTick(function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Download complete:\n%1\n\nOpen now?"), BD.filepath(saved_path)),
                    ok_text = _("Open"),
                    ok_callback = function()
                        self:openDownloadedFile(saved_path)
                    end,
                    cancel_callback = function()
                        self:refreshFileManagerIfNeeded(saved_path)
                        self:showResultsDialog()
                    end,
                })
            end)
            return
        end

        UIManager:show(InfoMessage:new{
            text = _("Download finished, but no output file path was detected."),
            timeout = 6,
        })
        self:showResultsDialog()
    end)
end

function KindleFetch:refreshFileManagerIfNeeded(path)
    if not path or not self.ui or not self.ui.file_chooser then
        return
    end
    local dir = util.splitFilePathName(path)
    if self.ui.file_chooser.path == dir then
        self.ui.file_chooser:refreshPath()
    end
end

function KindleFetch:openDownloadedFile(path)
    if self.ui and self.ui.document and self.ui.switchDocument then
        self.ui:switchDocument(path)
        return
    end
    if self.ui and self.ui.openFile then
        self.ui:openFile(path)
        return
    end
    require("apps/reader/readerui"):showReader(path)
end

function KindleFetch:showSetRootDialog()
    local detected = self:getKindleFetchRoot()
    local input_default = self.root_override or detected or ""

    local dialog
    dialog = InputDialog:new{
        title = _("Set KindleFetch root path"),
        description = _("Path must contain 'bin/kindlefetch.sh'. Leave blank to auto-detect."),
        input = input_default,
        input_hint = "/mnt/us/extensions/kindlefetch",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input = util.trim(dialog:getInputText() or "")
                        if input == "" then
                            self.root_override = nil
                            G_reader_settings:delSetting(SETTINGS_KEYS.root_override)
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{
                                text = _("Using automatic KindleFetch path detection."),
                                timeout = 4,
                            })
                            self:refreshBrowser()
                            return
                        end

                        local normalized = self:normalizeRootPath(input)
                        if not normalized then
                            UIManager:show(InfoMessage:new{
                                text = _("Path is not a valid KindleFetch installation."),
                                show_icon = true,
                            })
                            return
                        end

                        self.root_override = normalized
                        G_reader_settings:saveSetting(SETTINGS_KEYS.root_override, normalized)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = T(_("KindleFetch root set to:\n%1"), BD.dirpath(normalized)),
                            timeout = 5,
                        })
                        self:refreshBrowser()
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return KindleFetch
