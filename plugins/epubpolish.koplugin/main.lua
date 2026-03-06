local Archiver = require("ffi/archiver")
local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local SETTINGS_KEYS = {
    remove_soft_hyphens = "epub_polish_remove_soft_hyphens",
    smarten_double_hyphen = "epub_polish_smarten_double_hyphen",
    compatibility_ascii_dashes = "epub_polish_compatibility_ascii_dashes",
    join_linebreak_hyphen = "epub_polish_join_linebreak_hyphen",
    open_after_polish = "epub_polish_open_after_polish",
    last_input_file = "epub_polish_last_input_file",
}

local TEXT_EXTENSIONS = {
    css = true,
    htm = true,
    html = true,
    ncx = true,
    opf = true,
    txt = true,
    xhtml = true,
    xml = true,
}

local STORE_EXTENSIONS = {
    avif = true,
    gif = true,
    gz = true,
    jpeg = true,
    jpg = true,
    m4a = true,
    mp3 = true,
    mp4 = true,
    png = true,
    webp = true,
    woff = true,
    woff2 = true,
}

local MAX_TEXT_FILE_BYTES = 4 * 1024 * 1024
local SOFT_HYPHEN = "\xC2\xAD"
local EM_DASH = "\xE2\x80\x94"
local DASH_FAMILY_PATTERN = "[\xE2][\x80][\x90-\x95]"
local MINUS_SIGN = "\xE2\x88\x92"

local EpubPolish = WidgetContainer:extend{
    name = "epubpolish",
    is_doc_only = false,
}

function EpubPolish:onDispatcherRegisterActions()
    Dispatcher:registerAction("polish_current_epub", {
        category = "none",
        event = "PolishCurrentEpub",
        title = _("Polish current EPUB"),
        reader = true,
    })
    Dispatcher:registerAction("polish_epub_file", {
        category = "none",
        event = "ChooseEpubForPolish",
        title = _("Polish EPUB file"),
        reader = true,
        filemanager = true,
    })
end

function EpubPolish:init()
    self:loadSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    logger.info("EPUB polish: plugin initialized")
end

function EpubPolish:loadSettings()
    self.remove_soft_hyphens = self:readBool(SETTINGS_KEYS.remove_soft_hyphens, true)
    self.smarten_double_hyphen = self:readBool(SETTINGS_KEYS.smarten_double_hyphen, true)
    self.compatibility_ascii_dashes = self:readBool(SETTINGS_KEYS.compatibility_ascii_dashes, false)
    self.join_linebreak_hyphen = self:readBool(SETTINGS_KEYS.join_linebreak_hyphen, false)
    self.open_after_polish = self:readBool(SETTINGS_KEYS.open_after_polish, true)
end

function EpubPolish:readBool(key, default_value)
    if G_reader_settings:has(key) then
        return G_reader_settings:isTrue(key)
    end
    return default_value
end

function EpubPolish:saveBool(key, value)
    G_reader_settings:saveSetting(key, value and true or false)
end

function EpubPolish:toggleOption(option_name)
    local new_value = not self[option_name]
    self[option_name] = new_value
    self:saveBool(SETTINGS_KEYS[option_name], new_value)
end

function EpubPolish:addToMainMenu(menu_items)
    menu_items.polish_current_epub = {
        text_func = function()
            if self:getCurrentEpubPath() then
                return _("Polish current EPUB")
            end
            return _("Polish EPUB file...")
        end,
        sorting_hint = "tools",
        callback = function()
            local current = self:getCurrentEpubPath()
            if current then
                self:onPolishPath(current)
            else
                self:onChooseEpubForPolish()
            end
        end,
    }

    menu_items.epub_polish = {
        text = _("EPUB polish"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    if self:getCurrentEpubPath() then
                        return _("Polish current EPUB")
                    end
                    return _("Polish EPUB file...")
                end,
                separator = true,
                callback = function()
                    local current = self:getCurrentEpubPath()
                    if current then
                        self:onPolishPath(current)
                    else
                        self:onChooseEpubForPolish()
                    end
                end,
            },
            {
                text = _("Choose EPUB from file browser"),
                callback = function()
                    self:onChooseEpubForPolish()
                end,
            },
            {
                text = _("Remove soft hyphens (U+00AD)"),
                checked_func = function()
                    return self.remove_soft_hyphens
                end,
                callback = function()
                    self:toggleOption("remove_soft_hyphens")
                end,
            },
            {
                text = _("Smarten double hyphens (-- to em dash)"),
                checked_func = function()
                    return self.smarten_double_hyphen
                end,
                callback = function()
                    self:toggleOption("smarten_double_hyphen")
                end,
            },
            {
                text = _("Compatibility mode: remove Unicode dash artifacts"),
                help_text = _("Converts word<dash>word to word word and removes leading dash markers such as <dash>Heading."),
                checked_func = function()
                    return self.compatibility_ascii_dashes
                end,
                callback = function()
                    self:toggleOption("compatibility_ascii_dashes")
                end,
            },
            {
                text = _("Join line-break hyphenation (heuristic)"),
                help_text = _("Joins words split as \"word-\\nnext\" when the next part starts with a lowercase ASCII letter."),
                checked_func = function()
                    return self.join_linebreak_hyphen
                end,
                callback = function()
                    self:toggleOption("join_linebreak_hyphen")
                end,
            },
            {
                text = _("Open polished EPUB after processing"),
                checked_func = function()
                    return self.open_after_polish
                end,
                callback = function()
                    self:toggleOption("open_after_polish")
                end,
            },
        },
    }
    logger.info("EPUB polish: menu entries registered")
end

function EpubPolish:getCurrentEpubPath()
    if not self.ui or not self.ui.document or not self.ui.document.file then
        return nil
    end
    local current_file = self.ui.document.file
    if util.getFileNameSuffix(current_file):lower() ~= "epub" then
        return nil
    end
    return current_file
end

function EpubPolish:isEpubPath(path)
    return path
        and lfs.attributes(path, "mode") == "file"
        and util.getFileNameSuffix(path):lower() == "epub"
end

function EpubPolish:onChooseEpubForPolish()
    local chooser_path
    if self.ui and self.ui.file_chooser and self.ui.file_chooser.path then
        -- In File Manager, always start from the currently browsed directory.
        chooser_path = self.ui.file_chooser.path
    else
        chooser_path = G_reader_settings:readSetting(SETTINGS_KEYS.last_input_file)
    end

    if chooser_path then
        local mode = lfs.attributes(chooser_path, "mode")
        if mode == "file" then
            chooser_path = ffiUtil.dirname(chooser_path)
        elseif mode ~= "directory" then
            chooser_path = nil
        end
    end
    if not chooser_path then
        chooser_path = G_reader_settings:readSetting("home_dir") or filemanagerutil.getDefaultDir()
    end

    local file_filter = function(path)
        return util.getFileNameSuffix(path):lower() == "epub"
    end
    local caller_callback = function(path)
        if self:isEpubPath(path) then
            G_reader_settings:saveSetting(SETTINGS_KEYS.last_input_file, path)
            self:onPolishPath(path)
        else
            UIManager:show(InfoMessage:new{
                text = _("Please choose a valid EPUB file."),
            })
        end
    end
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false,
        select_file = true,
        show_files = true,
        file_filter = file_filter,
        path = chooser_path,
        onConfirm = caller_callback,
    })
    return true
end

function EpubPolish:getOutputPath(input_path)
    local directory, filename = util.splitFilePathName(input_path)
    local base_name, suffix = util.splitFileNameSuffix(filename)
    suffix = suffix ~= "" and suffix or "epub"
    local stem = base_name .. "_polished"
    local output = string.format("%s%s.%s", directory, stem, suffix)
    local index = 2
    while lfs.attributes(output, "mode") == "file" do
        output = string.format("%s%s_%d.%s", directory, stem, index, suffix)
        index = index + 1
    end
    return output
end

function EpubPolish:getTransformSummary()
    local active = {}
    if self.remove_soft_hyphens then
        table.insert(active, _("remove soft hyphens"))
    end
    if self.smarten_double_hyphen then
        table.insert(active, _("smarten double hyphens"))
    end
    if self.compatibility_ascii_dashes then
        table.insert(active, _("compatibility mode: remove Unicode dash artifacts"))
    end
    if self.join_linebreak_hyphen then
        table.insert(active, _("join line-break hyphenation (heuristic)"))
    end
    if #active == 0 then
        return _("none (archive will still be repacked)")
    end
    return "- " .. table.concat(active, "\n- ")
end

function EpubPolish:onPolishCurrentEpub()
    local input_path = self:getCurrentEpubPath()
    if not input_path then
        UIManager:show(InfoMessage:new{
            text = _("Current document is not an EPUB."),
        })
        return true
    end
    return self:onPolishPath(input_path)
end

function EpubPolish:onPolishPath(input_path)
    if not self:isEpubPath(input_path) then
        UIManager:show(InfoMessage:new{
            text = _("Selected file is not a valid EPUB."),
        })
        return true
    end
    local output_path = self:getOutputPath(input_path)
    local transforms = self:getTransformSummary()
    UIManager:show(ConfirmBox:new{
        text = T(
            _("Create polished EPUB?\n\nInput:\n%1\n\nOutput:\n%2\n\nEnabled transforms:\n%3"),
            BD.filepath(input_path),
            BD.filepath(output_path),
            transforms
        ),
        ok_text = _("Polish"),
        ok_callback = function()
            self:runPolish(input_path, output_path)
        end,
    })
    return true
end

function EpubPolish:runPolish(input_path, output_path)
    local progress_box = InfoMessage:new{
        text = _("Polishing EPUB..."),
        timeout = 0,
    }
    UIManager:show(progress_box)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
        local ok, result = pcall(self.polishEpub, self, input_path, output_path)
        UIManager:close(progress_box)

        if not ok then
            logger.err("EpubPolish crashed:", result)
            UIManager:show(InfoMessage:new{
                text = T(_("Polish failed:\n%1"), tostring(result)),
                show_icon = true,
            })
            return
        end

        if not result.ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Polish failed:\n%1"), result.err),
                show_icon = true,
            })
            return
        end

        local text = T(
            _("Polished EPUB saved to:\n%1\n\nFiles written: %2\nFiles changed: %3\nReplacements: %4\nLarge text files skipped: %5"),
            BD.filepath(output_path),
            result.files_written,
            result.files_changed,
            result.replacements,
            result.skipped_large_text
        )

        if self.open_after_polish then
            UIManager:show(ConfirmBox:new{
                text = text .. "\n\n" .. _("Open polished EPUB now?"),
                ok_text = _("Open"),
                ok_callback = function()
                    self:openOutputFile(output_path)
                end,
            })
        else
            UIManager:show(InfoMessage:new{
                text = text,
                timeout = 8,
            })
        end
    end)
end

function EpubPolish:openOutputFile(path)
    if self.ui and self.ui.document then
        require("apps/reader/readerui"):showReader(path)
        return
    end
    if self.ui and self.ui.openFile then
        self.ui:openFile(path)
        return
    end
    require("apps/reader/readerui"):showReader(path)
end

function EpubPolish:isTextPath(path)
    local ext = util.getFileNameSuffix(path):lower()
    return TEXT_EXTENSIONS[ext] == true
end

function EpubPolish:shouldStoreUncompressed(path)
    local ext = util.getFileNameSuffix(path):lower()
    return STORE_EXTENSIONS[ext] == true
end

function EpubPolish:applyTransforms(content)
    local total_replacements = 0

    if self.remove_soft_hyphens then
        content, total_replacements = content:gsub(SOFT_HYPHEN, "")
    end

    if self.join_linebreak_hyphen then
        local n
        content, n = content:gsub("([%a][%a']+)%-%s*[\r\n]+%s*([%l][%a']+)", "%1%2")
        total_replacements = total_replacements + n
    end

    if self.smarten_double_hyphen then
        local n
        content, n = content:gsub("%-%-", EM_DASH)
        total_replacements = total_replacements + n
    end

    if self.compatibility_ascii_dashes then
        local n
        -- In noisy OCR/conversion sources, Unicode dashes are often artifacts.
        -- Heuristic:
        -- - word<dash>word -> word word
        -- - ><dash>Heading -> >Heading
        -- - remaining Unicode dashes -> space
        content, n = content:gsub("([%w])" .. DASH_FAMILY_PATTERN .. "([%w])", "%1 %2")
        total_replacements = total_replacements + n
        content, n = content:gsub("([%w])" .. MINUS_SIGN .. "([%w])", "%1 %2")
        total_replacements = total_replacements + n
        content, n = content:gsub(">%s*" .. DASH_FAMILY_PATTERN .. "%s*", ">")
        total_replacements = total_replacements + n
        content, n = content:gsub(">%s*" .. MINUS_SIGN .. "%s*", ">")
        total_replacements = total_replacements + n
        content, n = content:gsub(DASH_FAMILY_PATTERN, " ")
        total_replacements = total_replacements + n
        content, n = content:gsub(MINUS_SIGN, " ")
        total_replacements = total_replacements + n
        content = content:gsub("[ \t][ \t]+", " ")
    end

    return content, total_replacements
end

function EpubPolish:polishEpub(input_path, output_path)
    local tmp_path = output_path .. ".tmp"
    local now = os.time()

    if lfs.attributes(tmp_path, "mode") == "file" then
        os.remove(tmp_path)
    end

    local reader = Archiver.Reader:new()
    if not reader:open(input_path) then
        return { ok = false, err = _("Could not open input EPUB archive."), }
    end

    local writer = Archiver.Writer:new{}
    if not writer:open(tmp_path, "epub") then
        reader:close()
        return { ok = false, err = _("Could not create output EPUB archive."), }
    end

    local function fail(message)
        pcall(function() writer:close() end)
        pcall(function() reader:close() end)
        if lfs.attributes(tmp_path, "mode") == "file" then
            os.remove(tmp_path)
        end
        return { ok = false, err = message, }
    end

    local stats = {
        files_written = 0,
        files_changed = 0,
        replacements = 0,
        skipped_large_text = 0,
    }

    local mimetype = reader:extractToMemory("mimetype")
    writer:setZipCompression("store")
    if mimetype and mimetype ~= "" then
        writer:addFileFromMemory("mimetype", mimetype, now)
    else
        writer:addFileFromMemory("mimetype", "application/epub+zip", now)
    end
    writer:setZipCompression("deflate")
    stats.files_written = stats.files_written + 1

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local content = reader:extractToMemory(entry.path)
            if not content then
                return fail(T(_("Failed to extract '%1' from source EPUB."), entry.path))
            end

            if self:isTextPath(entry.path) then
                if #content > MAX_TEXT_FILE_BYTES then
                    stats.skipped_large_text = stats.skipped_large_text + 1
                else
                    local replacement_count
                    content, replacement_count = self:applyTransforms(content)
                    if replacement_count > 0 then
                        stats.files_changed = stats.files_changed + 1
                        stats.replacements = stats.replacements + replacement_count
                    end
                end
            end

            local mtime = entry.mtime or now
            if self:shouldStoreUncompressed(entry.path) then
                writer:addFileFromMemory(entry.path, content, true, mtime)
            else
                writer:addFileFromMemory(entry.path, content, mtime)
            end

            stats.files_written = stats.files_written + 1
            if (stats.files_written % 25) == 0 then
                collectgarbage()
            end
        end
    end

    writer:close()
    reader:close()

    local renamed, rename_err = os.rename(tmp_path, output_path)
    if not renamed then
        return fail(T(_("Could not move temp EPUB into place: %1"), tostring(rename_err)))
    end

    collectgarbage()
    collectgarbage()

    stats.ok = true
    return stats
end

return EpubPolish
