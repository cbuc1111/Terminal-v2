return function(system, code)
  print(system)
  print(code)
  
  local func = loadstring(code)
  func(system)
end
