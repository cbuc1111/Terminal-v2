return function(system, code)
  local func = loadstring(code)
  func()(system)
end
