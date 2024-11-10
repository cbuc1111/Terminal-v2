local module = {}
module.__index = module

function module:new(system)
  local self = setmetatable({}, self)
  self.data1 = "char"
  self.data2 = 5
  self.system = system
  return self
end

function module:add()
  self.system:system_out(self.data2 + 1)
end

return module
