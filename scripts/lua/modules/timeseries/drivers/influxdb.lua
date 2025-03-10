--
-- (C) 2021 - ntop.org
--
local driver = {}

-- NOTE: this script is required by second.lua, keep the imports minimal!
require "ntop_utils"
require "lua_utils_generic"
local ts_common = require("ts_common")
local json = require("dkjson")
local os_utils = require("os_utils")

--
-- Sample query:
--    select * from "iface:ndpi" where ifid='0' and protocol='SSL'
--
-- See also callback_utils.uploadTSdata
--

-- Export problems occur if the export queue length is >= INFLUX_MAX_EXPORT_QUEUE_LEN_HIGH.
-- Then, the problems are considered fixed once the queue length goes <= INFLUX_MAX_EXPORT_QUEUE_LEN_LOW.
-- NOTE: these values are multiplied by the number of interfaces
-- NOTE: a single file can be as big as 4MB.
local INFLUX_MAX_EXPORT_QUEUE_LEN_LOW = 10
local INFLUX_MAX_EXPORT_QUEUE_LEN_HIGH = 20
local INFLUX_MAX_EXPORT_QUEUE_TRIM_LEN = 30 -- This edge should never be crossed. If it does, queue is manually trimmed

local INFLUX_EXPORT_QUEUE = "ntopng.influx_file_queue"
local MIN_INFLUXDB_SUPPORTED_VERSION = "1.5.1"
local FIRST_AGGREGATION_TIME_KEY = "ntopng.prefs.influxdb.first_aggregation_time"

-- hourly continuous queries are disabled as they create a lot of pressure
-- on the InfluxDB database.
local HOURLY_CQ_ENABLED = false
local HOURLY_CQ_DISABLED_KEY = "ntopng.prefs.influxdb.1h_cq_disabled"

-- ##############################################

local INFLUX_KEY_PREFIX = "ntopng.cache.influxdb."

-- Keep total counters for dropped points
local INFLUX_KEY_EXPORTED_POINTS = INFLUX_KEY_PREFIX .. "num_exported_points"
local INFLUX_KEY_EXPORTS = INFLUX_KEY_PREFIX .. "num_exports"
local INFLUX_KEY_FAILED_EXPORTS = INFLUX_KEY_PREFIX .. "num_failed_exports"
local INFLUX_KEY_LAST_ERROR = INFLUX_KEY_PREFIX .. "last_error"

-- Use this flag as TTL-based redis keys to check wether the health
-- of influxdb is OK.
local INFLUX_FLAGS_TIMEOUT = 60 -- keep the issue for 60 seconds
local INFLUX_FLAG_DROPPING_POINTS = INFLUX_KEY_PREFIX .. "flag_dropping_points"
local INFLUX_FLAG_FAILING_EXPORTS = INFLUX_KEY_PREFIX .. "flag_failing_exports"

local INFLUX_QUEUE_FULL_FLAG = INFLUX_KEY_PREFIX .. "export_queue_full"

-- ##############################################

local function isExportQueueFull()
    return (ntop.getCache(INFLUX_QUEUE_FULL_FLAG) == "1")
end

local function setExportQueueFull(is_full)
    if (is_full) then
        ntop.setCache(INFLUX_QUEUE_FULL_FLAG, "1")
    else
        ntop.delCache(INFLUX_QUEUE_FULL_FLAG)
    end
end

-- ##############################################

local function where_tags(tags)
    if not table.empty(tags) then
        return ' WHERE ' .. table.tconcat(tags, "=", " AND ", nil, "'") .. " AND"
    else
        return " WHERE"
    end
end

-- ##############################################

local function getWhereClause(tags, tstart, tend, unaligned_offset)
    return where_tags(tags) .. ' time >= ' .. tstart .. '000000000 AND time <= ' .. (tend + unaligned_offset) ..
               "000000000"
end

-- ##############################################

local function urlencode(str)
    str = string.gsub(str, "\r?\n", "\r\n")
    str = string.gsub(str, "([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = string.gsub(str, " ", "+")
    return str
end

-- ##############################################

function driver:new(options)
    local obj = {
        url = options.url,
        db = options.db,
        username = options.username or "",
        password = options.password or "",
        has_full_export_queue = isExportQueueFull(),
        cur_dropped_points = 0
    }

    setmetatable(obj, self)
    self.__index = self

    return obj
end

-- ##############################################

local function getInfluxDBQueryTimeout()
    return tonumber(ntop.getPref("ntopng.prefs.influx_query_timeout")) or 10
end

-- ##############################################

local function del_all_vals()
    ntop.delCache(INFLUX_KEY_EXPORTED_POINTS)
    ntop.delCache(INFLUX_KEY_EXPORTS)
    ntop.delCache(INFLUX_KEY_FAILED_EXPORTS)
    ntop.delCache(INFLUX_FLAG_DROPPING_POINTS)
    ntop.delCache(INFLUX_FLAG_FAILING_EXPORTS)
end

-- ##############################################

function driver:get_exported_points()
    return tonumber(ntop.getCache(INFLUX_KEY_EXPORTED_POINTS)) or 0
end

-- ##############################################

function driver:get_exports()
    return tonumber(ntop.getCache(INFLUX_KEY_EXPORTS)) or 0
end

-- ##############################################

local function is_dropping_points()
    return ntop.getCache(INFLUX_FLAG_DROPPING_POINTS) == "true"
end

-- ##############################################

local function is_failing_exports()
    return ntop.getCache(INFLUX_FLAG_FAILING_EXPORTS) == "true"
end

-- ##############################################

-- This function is called when the object is destroyed (garbage collected)
function driver:__gc()
    -- Nothing to do
end

-- ##############################################

function driver:append(schema, timestamp, tags, metrics)
    if (self.has_full_export_queue) then
        -- Temporary buffer dropped points into a local counter.
        -- They will be exported to redis once the driver is dismissed in driver:__gc()
        self.cur_dropped_points = self.cur_dropped_points + 1
        return (false)
    end

    local rv = interface.appendInfluxDB(schema.name, timestamp, tags, metrics)

    if not rv then
        -- Unable to append the point for export
        self.cur_dropped_points = self.cur_dropped_points + 1
    end

    return rv
end

-- ##############################################

local function getResponseError(res)
    if res.CONTENT and res.CONTENT_TYPE == "application/json" then
        local jres = json.decode(res.CONTENT)

        if jres then
            if jres.error then
                if res.RESPONSE_CODE then
                    return "[" .. res.RESPONSE_CODE .. "] " .. jres.error
                else
                    return jres.error
                end
            elseif jres.results then
                for _, single_res in pairs(jres.results) do
                    if single_res.error then
                        return single_res.error, single_res.statement_id
                    end
                end
            end
        end
    end

    return res.RESPONSE_CODE or "unknown error"
end

-- ##############################################

local function getDatabaseRetentionDays()
    local data_retention_utils = require "data_retention_utils"
    return data_retention_utils.getTSAndStatsDataRetentionDays()
end

local function get1dDatabaseRetentionDays()
    return getDatabaseRetentionDays()
end

local function get1hDatabaseRetentionDays()
    return getDatabaseRetentionDays()
end

-- ##############################################

local function isRollupEnabled()
    return (ntop.getPref("ntopng.prefs.disable_influxdb_rollup") ~= "1")
end

-- ##############################################

-- Determines the most appropriate retention policy
local function getSchemaRetentionPolicy(schema, tstart, tend, options)
    if schema.options.influx_internal_query then
        return "raw"
    end

    options = options or {}
    local first_aggr_time = tonumber(ntop.getPref(FIRST_AGGREGATION_TIME_KEY))

    if ((not first_aggr_time) or (not isRollupEnabled())) then
        return "raw"
    end

    local rp_1d_duration_sec = get1dDatabaseRetentionDays() * 86400
    local rp_1h_duration_sec = get1hDatabaseRetentionDays() * 86400

    -- RP selection logic
    local oldest_1d_data = os.time() - rp_1d_duration_sec
    local oldest_1h_data = os.time() - rp_1h_duration_sec
    local oldest_raw_data = getDatabaseRetentionDays() * 86400
    local max_raw_interval = 12 * 3600 -- after 12 hours begin to use the aggregated data
    local max_1h_interval

    if (HOURLY_CQ_ENABLED) then
        max_1h_interval = 15 * 86400 -- after 15 days use the 1d aggregated data
    else
        max_1h_interval = 5 * 86400 -- after 5 days use the 1d aggregated data
    end

    if options.target_aggregation then
        if ((options.target_aggregation == "1h") and (tstart < oldest_1h_data)) or
            ((options.target_aggregation == "raw") and (tstart < oldest_raw_data)) then
            -- cannot satisfy the target_aggregation
        else
            -- user override
            return options.target_aggregation
        end
    end

    -- Fix the limits to ensure that the first_aggr_time is not crossed
    -- Crossing it is still acceptable for the options.target_aggregation check above
    oldest_1d_data = math.max(oldest_1d_data, first_aggr_time)
    oldest_1h_data = math.max(oldest_1h_data, first_aggr_time)

    if tstart < oldest_1d_data then
        return "raw"
    elseif tstart < oldest_1h_data then
        return "1d"
    elseif (HOURLY_CQ_ENABLED and (tstart < oldest_raw_data)) then
        return "1h"
    end

    local interval = tend - tstart

    if interval >= max_1h_interval then
        return "1d"
    elseif (HOURLY_CQ_ENABLED and (interval >= max_raw_interval)) then
        return "1h"
    end

    return "raw"
end

-- ##############################################

-- This is necessary to avoid fetching a point which is not already
-- aggregated by the retention policy
local function fixTendForRetention(tend, rp)
    local now = os.time()

    if (rp == "1h") then
        local current_hour = now - (now % 3600)
        return (math.min(tend, current_hour - 3600))
    elseif (rp == "1d") then
        local current_day = os.date("*t", now)
        current_day.min = 0
        current_day.sec = 0
        current_day.hour = 0
        current_day = os.time(current_day)
        return (math.min(tend, current_day - 86400))
    end

    return (tend)
end

-- ##############################################

-- returns schema_name, step
local function retentionPolicyToSchema(schema, rp, db)
    if ((rp == "raw") or (rp == "autogen")) then
        rp = nil
    end

    if not isEmptyString(rp) then
        -- counters become derivatives
        local metric_type = ternary(schema.options.metrics_type == ts_common.metrics.counter,
            ts_common.metrics.derivative, schema.options.metrics_type)
        return string.format('"%s"."%s"."%s"', db, rp, schema.name), ternary(rp == "1d", 86400, 3600), metric_type
    end

    -- raw
    return string.format('"%s"', schema.name), schema.options.step, schema.options.metrics_type
end

-- ##############################################

local function getQuerySchema(schema, tstart, tend, db, options)
    return retentionPolicyToSchema(schema, getSchemaRetentionPolicy(schema, tstart, tend, options), db)
end

-- ##############################################

local function influx_query_multi(base_url, query, username, password, options)
    options = options or {}
    local full_url = base_url .. "&q=" .. urlencode(query)
    local tstart = os.time()
    local timeout = ternary(options.no_timeout, 99999999999, getInfluxDBQueryTimeout())
    local res = ntop.httpGet(full_url, username, password, timeout, true)
    local tdiff = os.time() - tstart
    local debug_influxdb_queries = (ntop.getPref("ntopng.prefs.influxdb.print_queries") == "1")

    if debug_influxdb_queries then
        local _, num_queries = string.gsub(query, ";", "")
        traceError(TRACE_NORMAL, TRACE_CONSOLE,
            string.format("influx_query[#%u][%ds]: %s", num_queries + 1, tdiff, query))
    end

    if tdiff >= timeout then
        -- Show the error
        ntop.setCache(INFLUX_KEY_LAST_ERROR, i18n("graphs.influxdb_not_responding", {
            url = ntop.getHttpPrefix() .. "/lua/admin/prefs.lua?tab=on_disk_ts#influx_query_timeout",
            flask_icon = '<i class="fas fa-flask"></i>'
        }))
    end

    -- Log the query
    local msg = os.date("%d/%b/%Y %H:%M:%S ") .. query
    ntop.lpushCache("ntopng.trace.influxdb_queries", msg, 100 --[[ max queue elements ]] )

    if not res then
        traceError(TRACE_ERROR, TRACE_CONSOLE, "Invalid response for query: " .. full_url)
        return nil
    end

    if ((res.RESPONSE_CODE ~= 200) and (not res.IS_PARTIAL)) then
        traceError(TRACE_ERROR, TRACE_CONSOLE, "Bad response code[" .. res.RESPONSE_CODE .. "]: " .. (res.CONTENT or ""))
        return nil
    end

    if ((res.CONTENT == nil) or (res.IS_PARTIAL)) then
        ts_common.setLastError(ts_common.ERR_OPERATION_TOO_SLOW, i18n("graphs.query_too_slow"))
        return nil
    end

    local jres = json.decode(res.CONTENT)

    if (not jres) or (not jres.results) or (not #jres.results) then
        traceError(TRACE_ERROR, TRACE_CONSOLE,
            "Invalid JSON reply[" .. res.CONTENT_LEN .. " bytes]: " .. string.sub(res.CONTENT, 1, 50))
        return nil
    end

    for _, result in ipairs(jres.results) do
        if result["error"] then
            traceError(TRACE_ERROR, TRACE_CONSOLE, result["error"])
            return nil
        end
    end

    return jres
end

-- ##############################################

local function influx_query(base_url, query, username, password, options)
    local jres = influx_query_multi(base_url, query, username, password, options)

    if jres and jres.results then
        if not jres.results[1].series then
            -- no results found
            return {}
        end

        return jres.results[1]
    end

    return nil
end

-- ##############################################

local function multiQueryPost(queries, url, username, password)
    local query_str = table.concat(queries, ";")
    local res = ntop.httpPost(url .. "/query", "q=" .. urlencode(query_str), username, password,
        getInfluxDBQueryTimeout(), true)

    if not res then
        local err = "Invalid response for query: " .. query_str
        traceError(TRACE_ERROR, TRACE_CONSOLE, err)
        return false, err
    end

    if res.RESPONSE_CODE ~= 200 then
        local err = "Bad response code[" .. res.RESPONSE_CODE .. "]: " .. getResponseError(res)
        traceError(TRACE_ERROR, TRACE_CONSOLE, err)
        -- tprint(query_str)
        return false, err
    end

    local err, statement_id = getResponseError(res)
    if err ~= 200 then
        local err = "Unexpected query error: " .. err
        if statement_id ~= nil then
            err = err .. string.format(", in query #%d: %s", statement_id, queries[statement_id + 1] or "nil")
        end
        traceError(TRACE_ERROR, TRACE_CONSOLE, err)
        return false, err
    end

    return true
end

-- ##############################################

local function influx2Series(schema, tstart, tend, tags, options, data, time_step, last_ts)
    local series = {}
    local max_vals = {}
    last_ts = last_ts or os.time()

    -- Create the columns
    for i = 2, #data.columns do
        series[i - 1] = {
            label = data.columns[i],
            data = {}
        }
        max_vals[i - 1] = ts_common.getMaxPointValue(schema, series[i - 1].label, tags)
    end

    -- The first time available in the returned data
    local first_t = data.values[1][1]
    -- Align tstart to the first timestamp
    tstart = tstart + (first_t - tstart) % time_step

    -- next_t holds the expected timestamp of the next point to process
    local next_t = tstart
    -- the next index to use for insertion in the result table
    local series_idx = 1
    -- tprint(time_step .. ") " .. tstart .. " vs " .. first_t .. " - " .. next_t)

    -- Convert the data
    for idx, values in ipairs(data.values) do
        local cur_t = data.values[idx][1]

        if #values < 2 or cur_t < tstart then
            -- skip empty points (which are out of query bounds)
            goto continue
        end

        if (cur_t > last_ts) then
            -- skip values exceeding the last point
            break
        end

        -- Fill the missing points
        while ((cur_t - next_t) >= time_step) do
            for _, serie in pairs(series) do
                serie.data[series_idx] = options.fill_value
            end

            -- tprint("FILL [" .. series_idx .."] " .. cur_t .. " vs " .. next_t)
            series_idx = series_idx + 1
            next_t = next_t + time_step
        end

        for i = 2, #values do
            local val = ts_common.normalizeVal(values[i], max_vals[i - 1], options)
            series[i - 1].data[series_idx] = val
        end

        -- traceError(TRACE_NORMAL, TRACE_CONSOLE, string.format("@ %u = %.2f", cur_t, values[2]))
        if (false) then -- consistency check
            local expected_t = next_t
            local actual_t = values[1]

            if math.abs(expected_t - actual_t) >= time_step then
                traceError(TRACE_WARNING, TRACE_CONSOLE, string.format(
                    "Bad point timestamp: expected %u, found %u [value = %.2f]", expected_t, actual_t, values[2]))
            end
        end

        series_idx = series_idx + 1
        next_t = next_t + time_step

        ::continue::
    end

    -- Fill the missing points at the end
    while ((tend - next_t) >= 0) do
        -- NOTE: fill_series is required for composed charts. In such case,
        -- not filling the serie would result into an incorrect upsampling
        if ((not options.fill_series) and (next_t > last_ts)) then
            -- skip values exceeding the last point
            break
        end

        for _, serie in pairs(series) do
            serie.data[series_idx] = options.fill_value
        end

        -- tprint("FILL [" .. series_idx .."] " .. tend .. " vs " .. next_t)
        series_idx = series_idx + 1
        next_t = next_t + time_step
    end

    -- In case just one point is found, report as no points are found
    for _, serie in pairs(series) do
        local num_not_nan_pts = 0
        for _, num in pairs(serie.data) do
            -- Not NAN points
            if num == num then
                num_not_nan_pts = num_not_nan_pts + 1
            end
        end

        -- Too few points to have a decent ts, reset all
        if num_not_nan_pts < options.min_num_points then
            for idx, num in pairs(serie.data) do
                serie.data[idx] = options.fill_value
            end
        end
    end

    local count = series_idx - 1

    return series, count, tstart
end

-- Test only
driver._influx2Series = influx2Series

-- ##############################################

local function getTotalSerieQuery(schema, query_schema, raw_step, tstart, tend, tags, time_step, data_type, label)
    label = label or "total_serie"

    --[[
  SELECT NON_NEGATIVE_DERIVATIVE(total_serie) AS total_serie FROM               // derivate the serie, if necessary
    (SELECT MEAN("total_serie") AS "total_serie" FROM                           // sample the total serie points, if necessary
      (SELECT SUM("value") AS "total_serie" FROM                                // sum all the series together
        (SELECT (bytes_sent + bytes_rcvd) AS "value" FROM "host:ndpi"           // possibly sum multiple metrics within same serie
          WHERE host='192.168.43.18' AND ifid='2'
          AND time >= 1531916170000000000 AND time <= 1532002570000000000)
        GROUP BY time(300s))
      GROUP BY time(600s))
  ]]
    local is_single_serie = schema:allTagsDefined(tags)
    local simplified_query = 'SELECT (' .. table.concat(schema._metrics, " + ") .. ') AS "' .. label .. '" FROM ' ..
                                 query_schema .. where_tags(tags) .. ' time >= ' .. tstart .. '000000000 AND time <= ' ..
                                 tend .. '000000000'

    local query

    if is_single_serie then
        -- optimized version
        query = simplified_query
    else
        query = 'SELECT SUM("' .. label .. '") AS "' .. label .. '" FROM (' .. simplified_query .. ')' ..
                    ' GROUP BY time(' .. raw_step .. 's)'
    end

    if time_step and (raw_step ~= time_step) then
        -- sample the points
        query =
            'SELECT MEAN("' .. label .. '") AS "' .. label .. '" FROM (' .. query .. ') GROUP BY time(' .. time_step ..
                's)'
    end

    if data_type == ts_common.metrics.counter then
        local optimized = false

        if (query == simplified_query) and (#schema._metrics == 1) then
            -- Remove nested query if possible
            local parts = split(query, " FROM ")

            if #parts == 2 then
                query = "SELECT NON_NEGATIVE_DERIVATIVE(" .. schema._metrics[1] .. ") AS " .. label .. " FROM " ..
                            parts[2]
            end
        end

        if not optimized then
            query = "SELECT NON_NEGATIVE_DERIVATIVE(" .. label .. ") AS " .. label .. " FROM (" .. query .. ")"
        end
    end

    return query
end

-- ##############################################

local function getLastTsQuery(schema, query_schema, tags)
    return string.format('SELECT LAST(' .. schema._metrics[1] .. ') FROM %s WHERE 1=1 AND %s', query_schema,
        table.tconcat(tags, "=", " AND ", nil, "'"))
end

-- ##############################################

function driver:_makeTotalSerie(schema, query_schema, raw_step, tstart, tend, tags, options, url, time_step, label,
    unaligned_offset, data_type)
    local query = getTotalSerieQuery(schema, query_schema, raw_step, tstart, tend + unaligned_offset, tags, time_step,
        data_type, label)
    local last_ts_query = getLastTsQuery(schema, query_schema, tags)
    local jres = influx_query_multi(url .. "/query?db=" .. self.db .. "&epoch=s",
        string.format("%s;%s", query, last_ts_query), self.username, self.password, options)
    local last_ts = os.time()
    local data = {}

    if (jres and jres.results and (#jres.results == 2)) then
        if jres.results[1].series then
            data = jres.results[1]
        end

        if jres.results[2].series and jres.results[2].series[1].values then
            last_ts = jres.results[2].series[1].values[1][1]
        end
    end

    if table.empty(data) then
        local rv = {}
        local i = 1

        for t = tstart + time_step, tend, time_step do
            rv[i] = 0
            i = i + 1
        end

        return rv
    end

    data = data.series[1]

    local series, count, tstart = influx2Series(schema, tstart + time_step, tend, tags, options, data, time_step,
        last_ts)
    return series[1].data
end

-- ##############################################

-- NOTE: mean / percentile values are calculated manually because of an issue with
-- empty points in the queries https://github.com/influxdata/influxdb/issues/6967
function driver:_performStatsQuery(stats_query, tstart, tend)
    local data = influx_query(self.url .. "/query?db=" .. self.db .. "&epoch=s", stats_query, self.username,
        self.password)

    if (data and data.series and data.series[1] and data.series[1].values[1]) then
        local data_stats = data.series[1].values[1]
        local total = data_stats[2]

        return {
            total = total,
            average = (total / (tend - tstart))
        }
    end

    return nil
end

-- ##############################################

local function getDatabaseName(schema, db)
    return ternary(schema.options.influx_internal_query, '_internal', db)
end

function driver:_makeSeriesQuery(query_schema, metrics, tags, tstart, tend, time_step, schema)
    local internal_query = schema.options.influx_internal_query

    if internal_query ~= nil then
        return internal_query(self, schema, tstart, tend, time_step)
    end

    return 'SELECT ' .. table.concat(metrics, ",") .. ' FROM ' .. query_schema .. where_tags(tags) .. " time >= " ..
               tstart .. "000000000 AND time <= " .. tend .. "000000000" .. " GROUP BY TIME(" .. time_step .. "s)"
end

-- ##############################################

function driver:query(schema, tstart, tend, tags, options)
    local metrics = {}
    local retention_policy = getSchemaRetentionPolicy(schema, tstart, tend, options)
    local query_schema, raw_step, data_type = retentionPolicyToSchema(schema, retention_policy, self.db)

    tend = fixTendForRetention(tend, retention_policy)
    local time_step = ts_common.calculateSampledTimeStep(raw_step, tstart, tend, options)

    if time_step >= 3600 then
        time_step = math.floor((time_step / 2) + 0.5)
        options.max_num_points = options.max_num_points * 2
    end

    -- NOTE: this offset is necessary to fix graph edge points when data insertion is not aligned with tstep
    local unaligned_offset = raw_step - 1

    for i, metric in ipairs(schema._metrics) do
        -- NOTE: why we need to device by time_step ? is MEAN+GROUP BY TIME bugged?
        if data_type == ts_common.metrics.counter then
            metrics[i] = "(DERIVATIVE(MEAN(\"" .. metric .. "\")) / " .. time_step .. ") as " .. metric
        else -- gauge / derivative
            metrics[i] = schema:getAggregationFunction() .. "(\"" .. metric .. "\") as " .. metric
        end
    end

    -- NOTE: GROUP BY TIME and FILL do not work well together! Additional zeroes produce non-existent derivative values
    -- Will perform fill manually below
    --[[
  SELECT (DERIVATIVE(MEAN("bytes")) / 60) as bytes
    FROM "iface:ndpi" WHERE protocol='SSL' AND ifid='2'
    AND time >= 1531991910000000000 AND time <= 1532002710000000000
    GROUP BY TIME(60s)
  ]]
    local query = self:_makeSeriesQuery(query_schema, metrics, tags, tstart, tend + unaligned_offset, time_step, schema)

    local url = self.url
    local data = {}
    local series, count

    -- Perform an additional query to determine the last point in the raw data
    local last_ts_query = getLastTsQuery(schema, query_schema, tags)

    local jres = influx_query_multi(url .. "/query?db=" .. getDatabaseName(schema, self.db) .. "&epoch=s",
        string.format("%s;%s", query, last_ts_query), self.username, self.password, options)
    local last_ts = os.time()

    if (jres and jres.results and (#jres.results == 2)) then
        if jres.results[1].series then
            data = jres.results[1]
        end

        if jres.results[2].series and jres.results[2].series[1].values then
            last_ts = jres.results[2].series[1].values[1][1]
        end
    end

    if table.empty(data) then
        series, count = ts_common.fillSeries(schema, tstart + time_step, tend, time_step, options.fill_value)
    else
        -- Note: we are working with intervals because of derivatives. The first interval ends at tstart + time_step
        -- which is the first value returned by InfluxDB
        series, count, tstart = influx2Series(schema, tstart + time_step, tend, tags, options, data.series[1],
            time_step, last_ts)
    end

    local total_serie = nil
    local stats = nil

    if options.calculate_stats then
        local is_single_serie = (#series == 1)

        if is_single_serie then
            -- optimization
            -- table.clone needed as total_serie can be modified below (table.insert)
            total_serie = table.clone(series[1].data)
        else
            -- try to inherit label from existing series
            local label = series and series[1] and series[1].label
            total_serie = self:_makeTotalSerie(schema, query_schema, raw_step, tstart + time_step, tend, tags, options,
                url, time_step, label, unaligned_offset, data_type)
        end

        if total_serie then
            stats = ts_common.calculateStatistics(total_serie, time_step, tend - tstart, data_type)

            stats = stats or {}
            stats.by_serie = {}

            for k, v in pairs(series) do
                local s = ts_common.calculateStatistics(v.data, time_step, tend - tstart, data_type)
                -- Adding per timeseries min-max stats
                stats.by_serie[k] = table.merge(s, ts_common.calculateMinMax(v.data))

                -- Remove the total for now as it requires a complex computation (see below)
                s.total = nil
            end

            if stats.total ~= nil then
                -- override total and average
                -- NOTE: using -1 to avoid overflowing into the next hour

                local stats_query = "(SELECT " .. table.concat(schema._metrics, " + ") .. ' AS value FROM ' ..
                                        query_schema .. ' ' .. getWhereClause(tags, tstart, tend, -1) .. ")"
                if data_type == ts_common.metrics.counter then
                    stats_query = "(SELECT NON_NEGATIVE_DIFFERENCE(value) as value FROM " .. stats_query .. ")"
                end
                stats_query = "SELECT SUM(value) as value FROM " .. stats_query

                if data_type == ts_common.metrics.derivative then
                    stats_query = "SELECT (value * " .. time_step .. ") as value FROM (" .. stats_query .. ")"
                end

                stats = table.merge(stats, self:_performStatsQuery(stats_query, tstart, tend))
            end
        end
    end

    if options.initial_point then
        local initial_metrics = {}

        for idx, metric in ipairs(schema._metrics) do
            initial_metrics[idx] = "FIRST(" .. metric .. ")"
        end

        local query = self:_makeSeriesQuery(query_schema, metrics, tags, tstart - time_step, tstart + unaligned_offset,
            time_step, schema)
        local data = influx_query(url .. "/query?db=" .. getDatabaseName(schema, self.db) .. "&epoch=s", query,
            self.username, self.password, options)

        if table.empty(data) then
            -- Data fill
            for _, serie in pairs(series) do
                table.insert(serie.data, 1, options.fill_value)
            end
        else
            local values = data.series[1].values[1]
            for i = 2, #values do
                local max_val = ts_common.getMaxPointValue(schema, series[i - 1].label, tags)
                local val = ts_common.normalizeVal(values[i], max_val, options)
                table.insert(series[i - 1].data, 1, val)
            end
        end

        -- shift tstart as we added one point
        tstart = tstart - time_step

        if total_serie then
            local label = series and series[1].label
            local additional_pt = self:_makeTotalSerie(schema, query_schema, raw_step, tstart - time_step, tstart, tags,
                options, url, time_step, label, unaligned_offset, data_type) or {options.fill_value}
            table.insert(total_serie, 1, additional_pt[1])
        end

        count = count + 1
    end

    if options.calculate_stats and total_serie then
        stats = table.merge(stats, ts_common.calculateMinMax(total_serie))
    end

    local rv = {
        start = tstart,
        step = time_step,
        raw_step = raw_step,
        count = count,
        series = series,
        statistics = stats,
        source_aggregation = retention_policy or "raw",
        additional_series = {
            total = total_serie
        }
    }

    return rv
end

-- ##############################################

function driver:timeseries_query(options)
    local metrics = {}

    if (options.tags.host) and tonumber(options.tags.host) then
        options.tags.host = nil
    end

    -- It seems that host is added when asking for subnet
    if (starts(options.schema, "subnet")) then
        options.tags.host = nil
    end

    local retention_policy = getSchemaRetentionPolicy(options.schema_info, options.epoch_begin, options.epoch_end,
        options)
    local query_schema, raw_step, data_type = retentionPolicyToSchema(options.schema_info, retention_policy, self.db)

    options.epoch_end = fixTendForRetention(options.epoch_end, retention_policy)
    local time_step = ts_common.calculateSampledTimeStep(raw_step, options.epoch_begin, options.epoch_end, options)

    if time_step >= 3600 then
        time_step = math.floor((time_step / 2) + 0.5)
        options.max_num_points = options.max_num_points * 2
    end

    -- NOTE: this offset is necessary to fix graph edge points when data insertion is not aligned with tstep
    local unaligned_offset = raw_step - 1

    for i, metric in ipairs(options.schema_info._metrics) do
        -- NOTE: why we need to device by time_step ? is MEAN+GROUP BY TIME bugged?
        if data_type == ts_common.metrics.counter then
            metrics[i] = "(DERIVATIVE(MEAN(\"" .. metric .. "\")) / " .. time_step .. ") as " .. metric
        else -- gauge / derivative
            metrics[i] = options.schema_info:getAggregationFunction() .. "(\"" .. metric .. "\") as " .. metric
        end
    end

    -- NOTE: GROUP BY TIME and FILL do not work well together! Additional zeroes produce non-existent derivative values
    -- Will perform fill manually below
    --[[
  SELECT (DERIVATIVE(MEAN("bytes")) / 60) as bytes
    FROM "iface:ndpi" WHERE protocol='SSL' AND ifid='2'
    AND time >= 1531991910000000000 AND time <= 1532002710000000000
    GROUP BY TIME(60s)
  ]]

    local query = self:_makeSeriesQuery(query_schema, metrics, options.tags, options.epoch_begin,
        options.epoch_end + unaligned_offset, time_step, options.schema_info)

    local url = self.url
    local data = {}
    local series, count

    -- Perform an additional query to determine the last point in the raw data
    local last_ts_query = getLastTsQuery(options.schema_info, query_schema, options.tags)

    local jres = influx_query_multi(url .. "/query?db=" .. getDatabaseName(options.schema_info, self.db) .. "&epoch=s",
        string.format("%s;%s", query, last_ts_query), self.username, self.password, options)
    local last_ts = os.time()

    if (jres and jres.results and (#jres.results == 2)) then
        if jres.results[1].series then
            data = jres.results[1]
        end

        if jres.results[2].series and jres.results[2].series[1].values then
            last_ts = jres.results[2].series[1].values[1][1]
        end
    end

    if table.empty(data) then
        series, count = ts_common.fillSeries(options.schema_info, options.epoch_begin + time_step, options.epoch_end,
            time_step, options.fill_value)
    else
        -- Note: we are working with intervals because of derivatives. The first interval ends at tstart + time_step
        -- which is the first value returned by InfluxDB
        series, count, options.epoch_begin = influx2Series(options.schema_info, options.epoch_begin + time_step,
            options.epoch_end, options.tags, options, data.series[1], time_step, last_ts)
    end

    -- The data received from influx is formatted as the following
    -- [
    --      [ epoch1, value1, value2 ], [ epoch2, value1, value2 ]
    -- ]

    local formatted_serie = {
        metadata = {},
        series = {}
    }

    for index, serie_data in pairs(series or {}) do
        local statistics = {}

        if options.calculate_stats then
            statistics = ts_common.calculateStatistics(serie_data.data, time_step,
                options.schema_info.options.keep_total, data_type)
            statistics = table.merge(statistics, ts_common.calculateMinMax(serie_data.data))
        end

        formatted_serie.series[#formatted_serie.series + 1] = {
            id = serie_data.label,
            data = serie_data.data,
            statistics = statistics
        }
    end

    formatted_serie.metadata.epoch_begin = options.epoch_begin
    formatted_serie.metadata.epoch_end = options.epoch_end
    formatted_serie.metadata.epoch_step = time_step
    formatted_serie.metadata.num_point = count
    formatted_serie.metadata.schema = options.schema
    formatted_serie.metadata.query = options.tags

    return formatted_serie
end

-- ##############################################

function driver:_exportErrorMsg(ret)
    local err_msg = i18n("delete_data.msg_err_unknown")
    local suffix = ""

    if ret ~= nil then
        if ret.error_msg ~= nil then
            err_msg = ret.error_msg .. "."
        elseif ret.CONTENT ~= nil then
            local content = json.decode(ret.CONTENT)

            if ((content ~= nil) and (content.error ~= nil)) then
                -- In case multiple lines are returned, only fetch the first one
                local errors = string.split(content.error, "\n") or {content.error}
                err_msg = errors[1] or content.error

                if string.find(err_msg, "max-values-per-tag limit exceeded", nil, true) ~= nil then
                    suffix = ". " .. i18n("alert_messages.influxdb_partial_write")
                end
            elseif ret.RESPONSE_CODE ~= nil then
                err_msg = err_msg .. " [" .. ret.RESPONSE_CODE .. "]"
            end
        elseif ret.RESPONSE_CODE ~= nil then
            err_msg = err_msg .. " [" .. ret.RESPONSE_CODE .. "]"
        end
    end

    return i18n("alert_messages.influxdb_write_error", {
        influxdb = self.url,
        err = err_msg
    }) .. suffix
end

-- ##############################################

-- Exports a timeseries file in line format to InfluxDB
-- Returns a tuple(success, file_still_existing)
function driver:_exportTsFile(exportable)
    local rv = true
    local fname = exportable["fname"]

    if not ntop.exists(fname) then
        traceError(TRACE_ERROR, TRACE_CONSOLE,
            string.format("Cannot find ts file %s. Some timeseries data will be lost.", fname))
        -- The file isn't in place, probably has been manually deleted or a write failure prevented
        -- it from being written. It's safe to remove the corresponding item from the queue as this
        -- won't be a recoverable export.
        ntop.lremCache(INFLUX_EXPORT_QUEUE, exportable["item"])
        return false
    end

    -- Delete the file after POST
    local delete_file_after_post = false
    -- Send data to InfluxDB
    local ret = ntop.postHTTPTextFile(self.username, self.password, self.url .. "/write?precision=s&db=" .. self.db,
        fname, delete_file_after_post, 30 --[[ timeout ]] )

    if ((ret == nil) or ((ret.RESPONSE_CODE ~= 200) and (ret.RESPONSE_CODE ~= 204))) then
        local msg = self:_exportErrorMsg(ret)
        ntop.setCache(INFLUX_KEY_LAST_ERROR, msg)

        rv = false
    else
        -- Clear last error
        ntop.delCache(INFLUX_KEY_LAST_ERROR)
    end

    return rv
end

-- ##############################################

-- Returns an indication of the current InfluxDB health.
-- Health is "green" when everything is working as expected,
-- "yellow" when there are recoverable issues, or "red" when
-- there is some critical error.
-- Health corresponds to the current status, i.e., a past
-- error, will no longer be considered
function driver:get_health()
    if is_dropping_points() then
        return "red"
    elseif is_failing_exports() then
        return "yellow"
    end

    return "green"
end

-- ##############################################

-- This is a function called by the periodic script influx.lua

function driver:export()
    local base_dir = dirs.workingdir .. "/tmp/influxdb"
    local files = ntop.readdir(base_dir)
    local num_files = 0
    local num_files_threshold = 60 -- No more than 60 imports per run

    for _, name in pairs(files) do
        if (ends(name, ".tmp") == false) then
            -- skip tmp files
            local fname = base_dir .. "/" .. name
            local delete_file_after_post = true
            local ret = ntop.postHTTPTextFile(self.username, self.password,
                self.url .. "/write?precision=s&db=" .. self.db, fname, delete_file_after_post, 30 --[[ timeout ]] )

            if ((ret == nil) or ((ret.RESPONSE_CODE ~= 200) and (ret.RESPONSE_CODE ~= 204))) then
                local msg = self:_exportErrorMsg(ret)
                ntop.setCache(INFLUX_KEY_LAST_ERROR, msg)
            else
                -- Clear last error
                ntop.delCache(INFLUX_KEY_LAST_ERROR)
                ntop.incrCache(INFLUX_KEY_EXPORTS, num_points)
            end

            -- io.write("[InfluxDB] Processed file "..fname.."\n")

            num_files = num_files + 1

            if (num_files > num_files_threshold) then
                -- Remaining files will be imported at the next run
                break
            end
        end
    end
end

-- ##############################################

function driver:getLatestTimestamp(ifid)
    local k = "ntopng.cache.influxdb_export_time_" .. self.db .. "_" .. ifid
    local v = tonumber(ntop.getCache(k))

    if v ~= nil then
        return v
    end

    return os.time()
end

-- ##############################################

-- At least 2 values are needed otherwise derivative will return empty
local min_values_list_series = 2

local function makeListSeriesQuery(schema, tags_filter, wildcard_tags, start_time, end_time)
    -- NOTE: do not use getQuerySchema here, otherwise we'll miss series

    -- NOTE: time based query not currently supported on show tags/series, using select
    -- https://github.com/influxdata/influxdb/issues/5668
    --[[
  SELECT * FROM "iface:ndpi_categories"
    WHERE ifid='2' AND time >= 1531981349000000000
    GROUP BY category
    LIMIT 2
  ]]
    if end_time ~= nil then
        return 'SELECT * FROM "' .. schema.name .. '"' .. where_tags(tags_filter) .. " time >= " .. start_time ..
                   "000000000" .. " AND time <= " .. end_time .. "000000000" ..
                   ternary(not table.empty(wildcard_tags), " GROUP BY " .. table.concat(wildcard_tags, ","), "") ..
                   " LIMIT " .. min_values_list_series
    else
        return 'SELECT * FROM "' .. schema.name .. '"' .. where_tags(tags_filter) .. " time >= " .. start_time ..
                   "000000000" ..
                   ternary(not table.empty(wildcard_tags), " GROUP BY " .. table.concat(wildcard_tags, ","), "") ..
                   " LIMIT " .. min_values_list_series
    end
end

local function processListSeriesResult(data, schema, tags_filter, wildcard_tags)
    if table.empty(data) then
        return nil
    end

    if table.empty(data.series) then
        return nil
    end

    if table.empty(wildcard_tags) then
        -- Simple "exists" check
        if #data.series[1].values >= min_values_list_series then
            return {tags_filter}
        else
            return nil
        end
    end

    local res = {}

    for _, serie in pairs(data.series) do
        if #serie.values < min_values_list_series then
            goto continue
        end

        for _, value in pairs(serie.values) do
            local tags = {}

            for i = 2, #value do
                local tag = serie.columns[i]

                -- exclude metrics
                if schema.tags[tag] ~= nil then
                    tags[tag] = value[i]
                end
            end

            for key, val in pairs(serie.tags) do
                tags[key] = val
            end

            res[#res + 1] = tags
            break
        end

        ::continue::
    end

    return res
end

-- ##############################################

function driver:listSeries(schema, tags_filter, wildcard_tags, start_time, end_time)
    local query = makeListSeriesQuery(schema, tags_filter, wildcard_tags, start_time, end_time)
    local url = self.url
    local data = influx_query(url .. "/query?db=" .. self.db, query, self.username, self.password)

    return processListSeriesResult(data, schema, tags_filter, wildcard_tags)
end

-- ##############################################

function driver:exists(schema, tags_filter, wildcard_tags)
    if schema.options.influx_internal_query then
        -- internal metrics always exist
        return (true)
    end

    -- Ignore wildcard_tags to avoid exessive points returned due to group by
    wildcard_tags = {}

    local query = makeListSeriesQuery(schema, tags_filter, wildcard_tags, 0)
    local url = self.url
    local data = influx_query(url .. "/query?db=" .. self.db, query, self.username, self.password)

    return (not table.empty(processListSeriesResult(data, schema, tags_filter, wildcard_tags)))
end

-- ##############################################

function driver:listSeriesBatched(batch)
    local max_batch_size = 30
    local url = self.url
    local rv = {}
    local idx_to_batchid = {}
    local internal_results = {}

    for i = 1, #batch, max_batch_size do
        local queries = {}

        -- Prepare the batch
        for j = i, math.min(i + max_batch_size - 1, #batch) do
            local cur_query = batch[j]

            if cur_query.schema.options.influx_internal_query then
                -- internal metrics always exist
                internal_results[j] = {{}} -- exists
            else
                local idx = #queries + 1
                idx_to_batchid[idx] = j
                queries[idx] = makeListSeriesQuery(cur_query.schema, cur_query.filter_tags, cur_query.wildcard_tags,
                    cur_query.start_time, cur_query.end_time or nil)

            end
        end
        local query_str = table.concat(queries, ";")
        local data = influx_query_multi(url .. "/query?db=" .. self.db, query_str, self.username, self.password)

        -- Collect the results
        if data and data.results then
            for idx, result in pairs(data.results) do
                local j = idx_to_batchid[idx]
                local cur_query = batch[j]
                local result = processListSeriesResult(result, cur_query.schema, cur_query.filter_tags,
                    cur_query.wildcard_tags)
                rv[j] = result
            end
        end
    end

    return table.merge(rv, internal_results)
end

-- ##############################################

function driver:topk(schema, tags, tstart, tend, options, top_tags)
    if #top_tags ~= 1 then
        traceError(TRACE_ERROR, TRACE_CONSOLE, "InfluxDB driver expects exactly one top tag, " .. #top_tags .. " found")
        return nil
    end

    local top_tag = top_tags[1]
    local retention_policy = getSchemaRetentionPolicy(schema, tstart, tend, options)
    local query_schema, raw_step, data_type = retentionPolicyToSchema(schema, retention_policy, self.db)
    tend = fixTendForRetention(tend, retention_policy)

    -- NOTE: this offset is necessary to fix graph edge points when data insertion is not aligned with tstep
    local unaligned_offset = raw_step - 1

    local derivate_metrics = {}
    local sum_metrics = {}
    local all_metrics = table.concat(schema._metrics, ", ")

    for idx, metric in ipairs(schema._metrics) do
        if data_type == "counter" then
            derivate_metrics[idx] = 'NON_NEGATIVE_DIFFERENCE(' .. metric .. ') as ' .. metric
        else -- derivative
            derivate_metrics[idx] = '(' .. metric .. ' * ' .. raw_step .. ') as ' .. metric
        end
        sum_metrics[idx] = 'SUM(' .. metric .. ') as ' .. metric
    end

    --[[
    SELECT TOP(value,protocol,10) FROM
      (SELECT SUM(value) AS value FROM
        (SELECT NON_NEGATIVE_DIFFERENCE(value) as value FROM
          (SELECT protocol, (bytes_sent + bytes_rcvd) AS "value" FROM "host:ndpi" WHERE host='192.168.1.1'
            AND ifid='1' AND time >= 1537540320000000000 AND time <= 1537540649000000000)
          GROUP BY protocol)
        GROUP BY protocol)
  ]]
    -- Aggregate into 1 metric and filter
    local base_query = '(SELECT ' .. top_tag .. ', (' .. table.concat(schema._metrics, " + ") .. ') AS "value", ' ..
                           all_metrics .. ' FROM ' .. query_schema .. ' ' .. getWhereClause(tags, tstart, tend, -1) ..
                           ')'

    -- Calculate difference between counter values
    if data_type == "counter" then
        base_query = '(SELECT NON_NEGATIVE_DIFFERENCE(value) as value, ' .. table.concat(derivate_metrics, ", ") ..
                         ' FROM ' .. base_query .. " GROUP BY " .. top_tag .. ")"
    else
        -- derivative
        base_query = '(SELECT (value * ' .. raw_step .. ') as value, ' .. table.concat(derivate_metrics, ", ") ..
                         ' FROM ' .. base_query .. " GROUP BY " .. top_tag .. ")"
    end

    -- Sum the traffic
    base_query = '(SELECT SUM(value) AS value, ' .. table.concat(sum_metrics, ", ") .. ' FROM ' .. base_query ..
                     ' GROUP BY ' .. top_tag .. ')'

    -- Calculate TOPk
    local query = 'SELECT TOP(value,' .. top_tag .. ',' .. options.top .. '), ' .. all_metrics .. ' FROM ' .. base_query

    local url = self.url
    local data =
        influx_query(url .. "/query?db=" .. self.db .. "&epoch=s", query, self.username, self.password, options)

    if table.empty(data) then
        return data
    end

    if table.empty(data.series) then
        return {}
    end

    data = data.series[1]

    local res = {}

    for idx, value in pairs(data.values) do
        -- top value
        res[idx] = value[2]
    end

    local sorted = {}

    for idx in pairsByValues(res, rev) do
        local value = data.values[idx]

        if value[2] > 0 then
            local partials = {}

            for idx = 4, #value do
                partials[data.columns[idx]] = value[idx]
            end

            sorted[#sorted + 1] = {
                tags = table.merge(tags, {
                    [top_tag] = value[3]
                }),
                value = value[2],
                partials = partials
            }
        end
    end

    local time_step = ts_common.calculateSampledTimeStep(raw_step, tstart, tend, options)
    local label = data and data[1].label
    local total_serie = self:_makeTotalSerie(schema, query_schema, raw_step, tstart, tend, tags, options, url,
        time_step, label, unaligned_offset, data_type)
    local stats = nil

    if options.calculate_stats and total_serie then
        stats = ts_common.calculateStatistics(total_serie, time_step, tend - tstart, data_type)

        if stats.total ~= nil then
            -- override total and average
            -- NOTE: sum must be calculated on individual top_tag fields to avoid
            -- calculating DIFFERENCE on a decreasing serie (e.g. this can happend on a top hosts query
            -- when a previously seen host becomes idle, which causes its traffic contribution on the total to become zero on next points)
            local stats_query = "SELECT SUM(value) as value FROM " .. base_query
            stats = table.merge(stats, self:_performStatsQuery(stats_query, tstart, tend))
        end
    end

    if options.initial_point and total_serie then
        local additional_pt = self:_makeTotalSerie(schema, query_schema, raw_step, tstart - time_step, tstart, tags,
            options, url, time_step, label, unaligned_offset, data_type) or {options.fill_value}
        table.insert(total_serie, 1, additional_pt[1])

        -- shift tstart as we added one point
        tstart = tstart - time_step
    end

    if options.calculate_stats and total_serie then
        stats = table.merge(stats, ts_common.calculateMinMax(total_serie))
    end

    return {
        topk = sorted,
        statistics = stats,
        source_aggregation = retention_policy or "raw",
        additional_series = {
            total = total_serie
        }
    }
end

function driver:timeseries_top(options, top_tags)
    if #top_tags ~= 1 then
        traceError(TRACE_ERROR, TRACE_CONSOLE, "InfluxDB driver expects exactly one top tag, " .. #top_tags .. " found")
        return nil
    end

    local top_tag = top_tags[1]
    local retention_policy = getSchemaRetentionPolicy(options.schema_info, options.epoch_begin, options.epoch_end,
        options)
    local query_schema, raw_step, data_type = retentionPolicyToSchema(options.schema_info, retention_policy, self.db)
    options.epoch_end = fixTendForRetention(options.epoch_end, retention_policy)

    -- NOTE: this offset is necessary to fix graph edge points when data insertion is not aligned with tstep
    local unaligned_offset = raw_step - 1

    local derivate_metrics = {}
    local sum_metrics = {}
    local all_metrics = table.concat(options.schema_info._metrics, ", ")

    for idx, metric in ipairs(options.schema_info._metrics) do
        if data_type == "counter" then
            derivate_metrics[idx] = 'NON_NEGATIVE_DIFFERENCE(' .. metric .. ') as ' .. metric
        else -- derivative
            derivate_metrics[idx] = '(' .. metric .. ' * ' .. raw_step .. ') as ' .. metric
        end
        sum_metrics[idx] = 'SUM(' .. metric .. ') as ' .. metric
    end

    --[[
    SELECT TOP(value,protocol,10) FROM
      (SELECT SUM(value) AS value FROM
        (SELECT NON_NEGATIVE_DIFFERENCE(value) as value FROM
          (SELECT protocol, (bytes_sent + bytes_rcvd) AS "value" FROM "host:ndpi" WHERE host='192.168.1.1'
            AND ifid='1' AND time >= 1537540320000000000 AND time <= 1537540649000000000)
          GROUP BY protocol)
        GROUP BY protocol)
  ]]
    -- Aggregate into 1 metric and filter
    local base_query = '(SELECT ' .. top_tag .. ', (' .. table.concat(options.schema_info._metrics, " + ") ..
                           ') AS "value", ' .. all_metrics .. ' FROM ' .. query_schema .. ' ' ..
                           getWhereClause(options.tags, options.epoch_begin, options.epoch_end, -1) .. ')'

    -- Calculate difference between counter values
    if data_type == "counter" then
        base_query = '(SELECT NON_NEGATIVE_DIFFERENCE(value) as value, ' .. table.concat(derivate_metrics, ", ") ..
                         ' FROM ' .. base_query .. " GROUP BY " .. top_tag .. ")"
    else
        -- derivative
        base_query = '(SELECT (value * ' .. raw_step .. ') as value, ' .. table.concat(derivate_metrics, ", ") ..
                         ' FROM ' .. base_query .. " GROUP BY " .. top_tag .. ")"
    end

    -- Sum the traffic
    base_query = '(SELECT SUM(value) AS value, ' .. table.concat(sum_metrics, ", ") .. ' FROM ' .. base_query ..
                     ' GROUP BY ' .. top_tag .. ')'

    -- Calculate TOPk
    local query = 'SELECT TOP(value,' .. top_tag .. ',' .. options.top .. '), ' .. all_metrics .. ' FROM ' .. base_query

    local url = self.url
    local data =
        influx_query(url .. "/query?db=" .. self.db .. "&epoch=s", query, self.username, self.password, options)

    if table.empty(data) then
        return data
    end

    if table.empty(data.series) then
        return {}
    end

    data = data.series[1]

    local res = {}

    for idx, value in pairs(data.values) do
        -- top value
        res[idx] = value[2]
    end

    local time_step = ts_common.calculateSampledTimeStep(raw_step, options.epoch_begin, options.epoch_end, options)
    local sorted = {}
    local top_series = {}
    local id = "bytes"
    local num_point = 0

    if ends(options.schema, "packets") then
        id = "packets"
    elseif ends(options.schema, "hits") then
        id = "hits"
    end

    for idx in pairsByValues(res, rev) do
        local value = data.values[idx]

        if value[2] > 0 then
            local partials = {}

            for idx = 4, #value do
                partials[data.columns[idx]] = value[idx]
            end

            local options_merged = {}
            for key, value in pairs(options) do
                options_merged[key] = value
            end

            local query_tag = table.merge(options.tags, {
                [top_tag] = value[3]
            })
            options_merged.tags = query_tag
            options_merged.top = nil

            local top_serie = self:timeseries_query(options_merged)
            local total_serie = {}

            for _, values in pairs(top_serie.series or {}) do
                num_point = #values.data
                for index, serie_point in pairs(values.data or {}) do
                    if not total_serie[index] then
                        total_serie[index] = 0
                    end

                    total_serie[index] = total_serie[index] + serie_point
                end
            end
            local statistics = ts_common.calculateStatistics(total_serie, time_step,
                options.schema_info.options.keep_total, data_type)
            statistics = table.merge(statistics, ts_common.calculateMinMax(total_serie))

            local snmp_utils = require "snmp_utils"
            local snmp_cached_dev = require "snmp_cached_dev"
            local cached_device = snmp_cached_dev:create(options.tags.device)
            -- In case of flow exporters the data is port, in case of snmp it's if_index
            local ifindex = query_tag.if_index or query_tag.port
            local ext_label = nil
            if cached_device then
                ext_label = snmp_utils.get_snmp_interface_label(cached_device["interfaces"][ifindex])
                if isEmptyString(ext_label) then
                    ext_label = ifindex
                end
            end

            sorted[#sorted + 1] = {
                tags = query_tag,
                statistics = statistics,
                id = id,
                name = value[3],
                ext_label = ext_label,
                data = total_serie
            }
        end
    end

    return {
        metadata = {
            num_point = num_point,
            epoch_begin = options.epoch_begin,
            epoch_end = options.epoch_end,
            epoch_step = time_step,
            schema = options.schema,
            query = options.tags
        },
        series = sorted
    }
end

-- ##############################################

function driver:queryTotal(schema, tstart, tend, tags, options)
    local query_schema, raw_step, data_type = getQuerySchema(schema, tstart, tend, self.db, options)
    local query

    if tags.epoch_begin then
        tags.epoch_begin = nil
    end

    if tags.epoch_end then
        tags.epoch_end = nil
    end

    if data_type == ts_common.metrics.counter then
        local metrics = {}
        local sum_metrics = {}

        for i, metric in ipairs(schema._metrics) do
            metrics[i] = "NON_NEGATIVE_DIFFERENCE(" .. metric .. ") as " .. metric
            sum_metrics[i] = "SUM(" .. metric .. ") as " .. metric
        end

        -- SELECT SUM("bytes_sent") as "bytes_sent", SUM("bytes_rcvd") as "bytes_rcvd" FROM
        --  (SELECT DIFFERENCE("bytes_sent") AS "bytes_sent", DIFFERENCE("bytes_rcvd") AS "bytes_rcvd"
        --    FROM "host:traffic" WHERE ifid='1' AND host='192.168.1.1' AND time >= 1536321770000000000 AND time <= 1536322070000000000)
        query = 'SELECT ' .. table.concat(sum_metrics, ", ") .. ' FROM ' .. '(SELECT ' .. table.concat(metrics, ", ") ..
                    ' FROM ' .. query_schema .. where_tags(tags) .. ' time >= ' .. tstart .. '000000000 AND time <= ' ..
                    tend .. '000000000)'
    else
        -- gauge/derivative
        local metrics = {}

        for i, metric in ipairs(schema._metrics) do
            metrics[i] = "(SUM(" .. metric .. ")"

            if data_type == "derivative" then
                metrics[i] = metrics[i] .. " * " .. raw_step
            end

            metrics[i] = metrics[i] .. ") as " .. metric
        end

        query =
            'SELECT ' .. table.concat(metrics, ", ") .. ' FROM ' .. query_schema .. where_tags(tags) .. ' time >= ' ..
                tstart .. '000000000 AND time <= ' .. tend .. '000000000'
    end

    local url = self.url
    local data =
        influx_query(url .. "/query?db=" .. self.db .. "&epoch=s", query, self.username, self.password, options)

    if table.empty(data) then
        return data
    end

    data = data.series[1]
    local res = {}

    for i = 2, #data.columns do
        local metric = data.columns[i]
        local total = data.values[1][i]

        res[metric] = total
    end

    return res
end

-- ##############################################

function driver:queryMean(schema, tags, tstart, tend, options)
    local metrics = {}
    local query_schema = getQuerySchema(schema, tstart, tend, self.db, options)

    for i, metric in ipairs(schema._metrics) do
        metrics[i] = "MEAN(" .. metric .. ") as " .. metric
    end

    local query = 'SELECT ' .. table.concat(metrics, ", ") .. ' FROM ' .. query_schema .. where_tags(tags) ..
                      ' time >= ' .. tstart .. '000000000 AND time <= ' .. tend .. '000000000'

    local url = self.url
    local data = influx_query(url .. "/query?db=" .. self.db .. "&epoch=s", query, self.username, self.password)

    if table.empty(data) then
        return data
    end

    data = data.series[1]
    local res = {}

    for i = 2, #data.columns do
        local metric = data.columns[i]
        local average = data.values[1][i]

        res[metric] = average
    end

    return res
end

-- ##############################################

local function getInfluxdbVersion(url, username, password)
    local res = ntop.httpGet(url .. "/ping", username, password, getInfluxDBQueryTimeout(), true)
    if not res or ((res.RESPONSE_CODE ~= 200) and (res.RESPONSE_CODE ~= 204)) then
        local err_info = getResponseError(res)
        if err_info == 0 then
            err_info = i18n("prefs.is_influxdb_running")
        end
        local err = i18n("prefs.could_not_contact_influxdb", {
            msg = err_info
        })

        traceError(TRACE_ERROR, TRACE_CONSOLE, err)
        return nil, err
    end

    local content = res.CONTENT or ""
    -- case-insensitive match as HAProxy transforms headers to lowercase (see #3964)
    return string.match(content:lower(), "\nx%-influxdb%-version: v?([%d|%.]+)")
end

function driver:getInfluxdbVersion()
    return getInfluxdbVersion(self.url, self.username, self.password)
end

-- ##############################################

local function single_query(base_url, query, username, password)
    local data = influx_query(base_url, query, username, password)

    if data and data.series and data.series[1] and data.series[1].values[1] then
        return data.series[1].values[1][2]
    end

    return nil
end

-- ##############################################

function driver:getDiskUsage()
    local query = 'SELECT SUM(last) FROM (select LAST(diskBytes) FROM "monitor"."shard" where "database" = \'' ..
                      self.db .. '\' group by id)'
    return single_query(self.url .. "/query?db=_internal", query, self.username, self.password)
end

-- ##############################################

function driver:getMemoryUsage()
    --[[
     This function attempts to match the memory used by the process, memory which is
     the top/htop RSS (Resident Stack Size) which is what it actually matters.

     InfluxDB docs leak explanations of how to interpred memory-related numbers:
     https://docs.influxdata.com/platform/monitoring/influxdata-platform/tools/measurements-internal/#runtime

     So the formula below has been obtained by tentatives and it seems to be pretty
     close to what top reports.
  --]]
    local query = 'SELECT LAST(Sys) - LAST(HeapReleased) FROM "_internal".."runtime"'
    return single_query(self.url .. "/query?db=_internal", query, self.username, self.password)
end

-- ##############################################

function driver:getSeriesCardinality()
    local query = 'SELECT LAST("numSeries") FROM "_internal".."database" where "database"=\'' .. self.db .. '\''
    return single_query(self.url .. "/query?db=_internal", query, self.username, self.password)
end

-- ##############################################

function driver.getShardGroupDuration(days_retention)
    -- https://docs.influxdata.com/influxdb/v1.7/query_language/database_management/#description-of-syntax-1
    if days_retention < 2 then
        return "1h"
    elseif days_retention < 180 then
        return "1d"
    else
        return "7d"
    end
end

local function makeRetentionPolicyQuery(statement, rpname, dbname, retention)
    return (string.format('%s RETENTION POLICY "%s" ON "%s" DURATION %ud REPLICATION 1 SHARD DURATION %s', statement,
        rpname, dbname, retention, driver.getShardGroupDuration(retention)))
end

-- ##############################################

local function updateCQRetentionPolicies(dbname, url, username, password)
    local query = string.format("SHOW RETENTION POLICIES ON %s", dbname)
    local res = influx_query(url .. "/query?db=" .. dbname, query, username, password)
    local rp_1h_statement = "CREATE"
    local rp_1d_statement = "CREATE"
    local create_1h, create_1d = true, true

    if res and res.series and res.series[1] then
        for _, rp in pairs(res.series[1].values) do
            local rp_name = rp[1]

            if rp_name == "1h" then
                create_1h = false
            elseif rp_name == "1d" then
                create_1d = false
            end
        end
    end

    local queries = {}

    if create_1d then
        queries[#queries + 1] = makeRetentionPolicyQuery(rp_1d_statement, "1d", dbname, get1dDatabaseRetentionDays())
    end

    if create_1h and HOURLY_CQ_ENABLED then
        queries[#queries + 1] = makeRetentionPolicyQuery(rp_1h_statement, "1h", dbname, get1hDatabaseRetentionDays())
    end

    return #queries > 0 and multiQueryPost(queries, url, username, password) or true
end

-- ##############################################

local function toVersion(version_str)
    local parts = string.split(version_str, "%.")

    if (#parts ~= 3) then
        return nil
    end

    return {
        major = tonumber(parts[1]) or 0,
        minor = tonumber(parts[2]) or 0,
        patch = tonumber(parts[3]) or 0
    }
end

local function isCompatibleVersion(version)
    local current = toVersion(version)
    local required = toVersion(MIN_INFLUXDB_SUPPORTED_VERSION)

    if (current == nil) or (required == nil) then
        return false
    end

    return (current.major == required.major) and
               ((current.minor > required.minor) or
                   ((current.minor == required.minor) and (current.patch >= required.patch)))
end

function driver.init(dbname, url, days_retention, username, password, verbose)
    require "lua_utils"
    local timeout = getInfluxDBQueryTimeout()

    -- Check version
    if verbose then
        traceError(TRACE_NORMAL, TRACE_CONSOLE, "Contacting influxdb at " .. url .. " ...")
    end

    local version, err = getInfluxdbVersion(url, username, password)

    if ((not version) and (err ~= nil)) then
        ntop.setCache(INFLUX_KEY_LAST_ERROR, err)
        return false, err
    elseif ((not version) or (not isCompatibleVersion(version))) then
        local err = i18n("prefs.incompatible_influxdb_version_found", {
            required = MIN_INFLUXDB_SUPPORTED_VERSION,
            found = version,
            url = "https://portal.influxdata.com/downloads"
        })

        ntop.setCache(INFLUX_KEY_LAST_ERROR, err)
        traceError(TRACE_ERROR, TRACE_CONSOLE, err)
        return false, err
    end

    -- Check existing database (this is used to prevent db creationg error for unprivileged users)
    if verbose then
        traceError(TRACE_NORMAL, TRACE_CONSOLE, "Checking database " .. dbname .. " ...")
    end
    local query = "SHOW DATABASES"
    local res = ntop.httpPost(url .. "/query", "q=" .. query, username, password, timeout, true)
    local db_found = false

    if res and (res.RESPONSE_CODE == 200) and res.CONTENT then
        local reply = json.decode(res.CONTENT)

        if reply and reply.results and reply.results[1] and reply.results[1].series then
            local dbs = reply.results[1].series[1]

            if ((dbs ~= nil) and (dbs.values ~= nil)) then
                for _, row in pairs(dbs.values) do
                    local user_db = row[1]

                    if user_db == dbname then
                        db_found = true
                        break
                    end
                end
            end
        end
    end

    if not db_found then
        -- Create database
        if verbose then
            traceError(TRACE_NORMAL, TRACE_CONSOLE, "Creating database " .. dbname .. " ...")
        end
        local query = "CREATE DATABASE \"" .. dbname .. "\""

        local res = ntop.httpPost(url .. "/query", "q=" .. query, username, password, timeout, true)
        if not res or (res.RESPONSE_CODE ~= 200) then
            local err = i18n("prefs.influxdb_create_error", {
                db = dbname,
                msg = getResponseError(res)
            })

            ntop.setCache(INFLUX_KEY_LAST_ERROR, err)
            traceError(TRACE_ERROR, TRACE_CONSOLE, err)
            return false, err
        end
    end

    if not db_found or days_retention ~= nil then
        -- New database or config changed
        days_retention = days_retention or getDatabaseRetentionDays()

        -- Set retention
        if verbose then
            traceError(TRACE_NORMAL, TRACE_CONSOLE, "Setting retention for " .. dbname .. " ...")
        end
        local query = makeRetentionPolicyQuery("ALTER", "autogen", dbname, days_retention)

        -- tprint(query)
        local res = ntop.httpPost(url .. "/query", "q=" .. query, username, password, timeout, true)
        if not res or (res.RESPONSE_CODE ~= 200) then
            local warning = i18n("prefs.influxdb_retention_error", {
                db = dbname,
                msg = getResponseError(res)
            })

            traceError(TRACE_WARNING, TRACE_CONSOLE, warning)
            -- This is just a warning, we can proceed
            -- return false, err
        end

        -- NOTE: updateCQRetentionPolicies will be called automatically as driver:setup is triggered after this
    end

    ntop.delCache(INFLUX_KEY_LAST_ERROR)
    return true, i18n("prefs.successfully_connected_influxdb", {
        db = dbname,
        version = version
    })
end

-- ##############################################

function driver:delete(schema_prefix, tags)
    local url = self.url
    local measurement_pattern = ternary(schema_prefix == "", '//', '/^' .. schema_prefix .. ':/')
    local query = 'DELETE FROM ' .. measurement_pattern
    if not table.empty(tags) then
        query = query .. ' WHERE ' .. table.tconcat(tags, "=", " AND ", nil, "'")
    end
    local full_url = url .. "/query?db=" .. self.db .. "&q=" .. urlencode(query)

    local res = ntop.httpGet(full_url, self.username, self.password, getInfluxDBQueryTimeout(), true)

    if not res or (res.RESPONSE_CODE ~= 200) then
        traceError(TRACE_ERROR, TRACE_CONSOLE, getResponseError(res))
        return false
    end

    return true
end

-- ##############################################

function driver:deleteOldData(ifid)
    -- NOTE: retention is perfomed automatically based on the database retention policy,
    -- no need for manual intervention
    -- check https://docs.influxdata.com/influxdb/v1.7/query_language/database_management/#create-retention-policies-with-create-retention-policy
    return true
end

-- ##############################################

local function getCqQuery(dbname, tags, schema, source, dest, step, dest_step, resemple)
    local cq_name = string.format("%s__%s", schema.name, dest)
    local resemple_s = ""
    local _, _, data_type = retentionPolicyToSchema(schema, source, dbname)

    if resemple then
        resemple_s = "RESAMPLE FOR " .. resemple
    end

    if data_type == ts_common.metrics.counter then
        local sums = {}
        local diffs = {}

        for _, metric in ipairs(schema._metrics) do
            sums[#sums + 1] = string.format('(SUM(%s) / %u) as %s', metric, dest_step, metric)
            diffs[#diffs + 1] = string.format('NON_NEGATIVE_DIFFERENCE(%s) as %s', metric, metric)
        end

        sums = table.concat(sums, ",")
        diffs = table.concat(diffs, ",")

        --[[
    CREATE CONTINUOUS QUERY "iface:packets__1h" ON ntopng
    RESAMPLE FOR 2h
    BEGIN
      SELECT (SUM(packets)/3600) as packets
      INTO "1h"."iface:packets" FROM (
        SELECT NON_NEGATIVE_DIFFERENCE(packets) as packets
          FROM "autogen"."iface:packets"
      ) GROUP BY time(1h),ifid
    END]]
        return string.format([[
      CREATE CONTINUOUS QUERY "%s" ON %s
      %s
      BEGIN
        SELECT
          %s
          INTO "%s"."%s"
          FROM (
            SELECT
              %s
              FROM "%s"."%s"
          ) GROUP BY time(%s)%s%s
      END]], cq_name, dbname, resemple_s, sums, dest, schema.name, diffs, source, schema.name, dest,
            ternary(isEmptyString(tags), "", ","), tags)
    else
        local means = {}

        for _, metric in ipairs(schema._metrics) do
            means[#means + 1] = string.format('%s(%s) as %s', schema:getAggregationFunction(), metric, metric)
        end

        means = table.concat(means, ",")

        --[[
    CREATE CONTINUOUS QUERY "asn:rtt__1h" ON ntopng
    RESAMPLE FOR 2h
    BEGIN
      SELECT MEAN(millis_rtt) as millis_rtt
      INTO "1h"."asn:rtt" FROM (
        SELECT MEAN(millis_rtt) as millis_rtt
        FROM "autogen"."asn:rtt"
        GROUP BY time(300s),ifid,asn FILL(0)
      ) GROUP BY time(1h),ifid,asn
    END]]
        return string.format([[
      CREATE CONTINUOUS QUERY "%s" ON %s
      %s
      BEGIN
        SELECT
          %s
          INTO "%s"."%s"
          FROM (
            SELECT
              %s
              FROM "%s"."%s"
              GROUP BY time(%us)%s%s
              FILL(0)
          ) GROUP BY time(%s)%s%s
      END]], cq_name, dbname, resemple_s, means, dest, schema.name, means, source, schema.name, step,
            ternary(isEmptyString(tags), "", ","), tags, dest, ternary(isEmptyString(tags), "", ","), tags)
    end
end

function driver:setup(ts_utils)
    local queries = {}
    local max_batch_size = 25 -- note: each query is about 400 characters
    local retention_changed = ntop.getCache("ntopng.influxdb.retention_changed") or '0'
    local retention = nil
    -- Clear saved values (e.g., number of exported points) as
    -- we want to start clean and keep values since-ntopng-startup
    del_all_vals()

    if retention_changed == '1' then
        retention = getDatabaseRetentionDays()
        ntop.delCache("ntopng.influxdb.retention_changed")
    end
    -- Ensure that the database exists
    driver.init(self.db, self.url, retention, self.username, self.password)

    if not updateCQRetentionPolicies(self.db, self.url, self.username, self.password) then
        traceError(TRACE_ERROR, TRACE_CONSOLE, "InfluxDB setup failed")
        return false
    end

    if not isRollupEnabled() then
        -- Nothing more to do
        return true
    end

    -- Continuos Queries stuff
    ts_utils.loadSchemas()
    local schemas = ts_utils.getLoadedSchemas()

    -- NOTE: continuos queries cannot be altered, so they must be manually
    -- dropped and created in case of changes
    for _, schema in pairs(ts_utils.getPossiblyChangedSchemas()) do
        if (HOURLY_CQ_ENABLED) then
            queries[#queries + 1] = 'DROP CONTINUOUS QUERY "' .. schema .. '__1h" ON ' .. self.db
        end

        queries[#queries + 1] = 'DROP CONTINUOUS QUERY "' .. schema .. '__1d" ON ' .. self.db
    end

    -- Needed to handle migration
    local previous_1h_enabled = not (ntop.getPref(HOURLY_CQ_DISABLED_KEY) == "1")
    local migration_necessary = (previous_1h_enabled ~= HOURLY_CQ_ENABLED)

    for _, schema in pairs(schemas) do
        local tags = table.concat(schema._tags, ",")

        if ((#schema._metrics == 0) or (schema.options.influx_internal_query)) then
            goto continue
        end

        if (migration_necessary) then
            -- NOTE: dropping all the continuous queries all together is not possible
            -- as InfluxDB does not provide an API for this and calling "SHOW CONTINUOUS QUERIES"
            -- yelds too much result data
            queries[#queries + 1] = 'DROP CONTINUOUS QUERY "' .. schema.name .. '__1h" ON ' .. self.db
            queries[#queries + 1] = 'DROP CONTINUOUS QUERY "' .. schema.name .. '__1d" ON ' .. self.db
        end

        if (HOURLY_CQ_ENABLED) then
            local cq_1h = getCqQuery(self.db, tags, schema, "autogen", "1h", schema.options.step, 3600, "2h")
            local cq_1d = getCqQuery(self.db, tags, schema, "1h", "1d", 3600, 86400)

            queries[#queries + 1] = cq_1h:gsub("\n", ""):gsub("%s%s+", " ")
            queries[#queries + 1] = cq_1d:gsub("\n", ""):gsub("%s%s+", " ")
        else
            local cq_1d = getCqQuery(self.db, tags, schema, "autogen", "1d", schema.options.step, 86400)

            queries[#queries + 1] = cq_1d:gsub("\n", ""):gsub("%s%s+", " ")
        end

        if #queries >= max_batch_size then
            if not multiQueryPost(queries, self.url, self.username, self.password) then
                traceError(TRACE_ERROR, TRACE_CONSOLE, "InfluxDB setup failed")
                return false
            end
            queries = {}
        end

        ::continue::
    end

    if #queries > 0 then
        if not multiQueryPost(queries, self.url, self.username, self.password) then
            traceError(TRACE_ERROR, TRACE_CONSOLE, "InfluxDB setup() failed")
            return false
        end
    end

    if (migration_necessary) then
        ntop.setPref(HOURLY_CQ_DISABLED_KEY, ternary(HOURLY_CQ_ENABLED, "0", "1"))

        -- Need to recalculate it
        ntop.delCache(FIRST_AGGREGATION_TIME_KEY)

        traceError(TRACE_NORMAL, TRACE_CONSOLE, "InfluxDB CQ migration completed")
    end

    if tonumber(ntop.getPref(FIRST_AGGREGATION_TIME_KEY)) == nil then
        local first_rp = ternary(HOURLY_CQ_ENABLED, "1h", "1d")
        local res = influx_query(self.url .. "/query?db=" .. self.db .. "&epoch=s",
            'SELECT FIRST(bytes) FROM "' .. first_rp .. '"."iface:traffic"', self.username, self.password)
        local first_t = os.time()

        if res and res.series and res.series[1].values then
            local v = res.series[1].values[1][1]

            if v ~= nil then
                first_t = v
            end
        end

        ntop.setPref(FIRST_AGGREGATION_TIME_KEY, tostring(first_t))
    end

    return true
end

-- ##############################################

function driver.getExportQueueLength()
    return (ntop.llenCache(INFLUX_EXPORT_QUEUE))
end

-- ##############################################

return driver
