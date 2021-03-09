--
-- (C) 2020 - ntop.org
--

local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path

require "lua_utils"
local template_utils = require("template_utils")

local ui_utils = {}

function ui_utils.render_configuration_footer(item)
    return template_utils.gen('pages/components/manage-configuration-link.template', {item = item})
end

--- Single note element: { content = 'note description', hidden = true|false }
function ui_utils.render_notes(notes_items, title, is_ordered)

    if notes_items == nil then
        traceError(TRACE_DEBUG, TRACE_CONSOLE, "The notes table is nil!")
        return ""
    end

    return template_utils.gen("pages/components/notes.template", {
        notes = notes_items,
        is_ordered = is_ordered,
        title = title
    })
end

function ui_utils.render_breadcrumb(title, items, icon)
    return template_utils.gen("pages/components/breadcrumb.template", {
        items = items,
        i18n_title = title,
        breadcrumb_icon = icon
    })
end

function ui_utils.render_pools_dropdown(pools_instance, member, key)

    if (pools_instance == nil) then
        traceError(TRACE_DEBUG, TRACE_CONSOLE, "The pools instance is nil!")
        return ""
    end

    if (member == nil) then
        traceError(TRACE_DEBUG, TRACE_CONSOLE, "The member is nil!")
        return ""
    end

    local selected_pool = pools_instance:get_pool_by_member(member)
    local selected_pool_id = selected_pool and selected_pool.pool_id or pools_instance.DEFAULT_POOL_ID

    local all_pools = pools_instance:get_all_pools()

    return template_utils.gen("pages/components/pool-select.template", {
        pools = all_pools,
        selected_pool_id = selected_pool_id,
        key = key,
    })
end

function ui_utils.create_navbar_title(title, subpage, title_link)
    if isEmptyString(subpage) then return title end
    return "<a href='".. title_link .."'>".. title .. "</a>&nbsp;/&nbsp;<span>"..subpage.."</span>"
end

function ui_utils.render_datetime_range_picker(begin_options, end_options)
    return template_utils.gen("pages/components/range-picker.template", {
        begin_options = begin_options,
        end_options = end_options
    })
end

--- Shortcut function to print a togglw switch inside the requested page
function ui_utils.print_toggle_switch(context)
    print(template_utils.gen("on_off_switch.html", context))
end

return ui_utils