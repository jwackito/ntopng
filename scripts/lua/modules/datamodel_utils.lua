--
-- (C) 2020 - ntop.org
--

local datamodel = {}
datamodel.__index = datamodel

local datamodel_colors = {
   'rgba(255, 127, 14, 1)',
   'rgba(174, 199, 232, 1)',
   'rgba(255, 187, 120, 1)',
   'rgba(31, 119, 180, 1)',
   'rgba(255, 99, 132, 1)',
   'rgba(54, 162, 235, 1)',
   'rgba(255, 206, 86, 1)',
   'rgba(75, 192, 192, 1)',
   'rgba(153, 102, 255, 1)',
   'rgba(255, 159, 64, 1)'
}

-- ######################################

function datamodel:create(labels)
   local ret = {}

   setmetatable(ret,datamodel)  -- Create the class
   
   ret.column_labels = labels
   ret.datasets      = {}

   return(ret)
end

-- ######################################

function datamodel:appendRow(when, dataset_name, row)
   if(self.datasets[dataset_name] == nil) then
      self.datasets[dataset_name] = {}

      self.datasets[dataset_name].rows       = {}
      self.datasets[dataset_name].timestamps = {}
   end

   table.insert(self.datasets[dataset_name].timestamps, when)
   table.insert(self.datasets[dataset_name].rows, row)

end

-- ######################################

-- Return the data formatted as expected by a table widget
function datamodel:getAsTable()
   local ret = {}
   local dataset_name

   -- take the first dataset
   for k,v in pairs(self.datasets) do
      dataset_name = k
   end
   
   ret.header = self.column_labels

   if(dataset_name == nil) then
      ret.rows = {}
   else
      ret.rows = self.datasets[dataset_name].rows
   end
   
   return(ret)
end

-- ######################################

-- Return the data formatted as expected by a table widget
function datamodel:getAsDonut()
   local ret = { data = {}}
   
   for k,v in pairs(self.datasets) do
      local i = 1
      
      for k1,v1 in pairs(v.rows) do
	 for k2,v2 in pairs(v1) do	 
	    table.insert(ret.data, { label = self.column_labels[i], value = v2 })
	    i = i + 1
	 end

	 ret.title = k
	 break 	 -- We expect only one entry
      end

   end
   
   return(ret)
end

-- ######################################

-- Return the data
function datamodel:getData(transformation, dataset_name)
   if(transformation == "table") then
      return(self:getAsTable())
   elseif(transformation == "donut") then
      return(self:getAsDonut())
   else
      return({})
   end
end

-- ######################################

return(datamodel)
