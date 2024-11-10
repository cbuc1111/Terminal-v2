local repr = require("repr")

local System = {}
System.__index = System

function System:new(system_disk, modem)
    local self = setmetatable({}, self)
    self.system_disk = system_disk
    self.modem = modem

    self.system_data = self.system_disk:Read("terminal_system")
    self.loaded_packages = {}
    return self
end

function System:boot()
    if not self:has_system() then
        self:setup_system()
    end

    self:load_packages()
end

function System:system_in(...)
    self:execute(...)
end

function System:system_out(...)
    print(...)
end

function System:load_package(contents)
    local loaded_package = loadstring(contents)
    loaded_package = loaded_package()
    return loaded_package
end

function System:load_packages()
    for package_name, package_contents in self.system_data.packages do
        self.loaded_packages[package_name] = self:load_package(package_contents)
    end
end

function System:download_core_packages()
    local CORE_PACKAGES_URL = "https://raw.githubusercontent.com/cbuc1111/Terminal-v2/refs/heads/main/core_packages/packages_list"
    local _, packages_list = self:download(CORE_PACKAGES_URL, true)

    for package_name, package_url in packages_list do
        local _, package_contents = self:download(package_url, false)
        self.system_data.packages[package_name] = package_contents
    end
end

function System:download(url, decode, ATTEMPTS_AMOUNT, ATTEMPTS_COOLDOWN)
    ATTEMPTS_AMOUNT = ATTEMPTS_AMOUNT or 5
    ATTEMPTS_COOLDOWN = ATTEMPTS_COOLDOWN or 1

    local attempts_done = 0
    local success, response

    while attempts_done < ATTEMPTS_AMOUNT do
        success, response = pcall(self.modem.GetAsync, self.modem, url)

        if success then
            break
        else
            attempts_done += 1
            self:system_out(`Failed to download from url, trying again... (attempt {attempts_done})`)
            task.wait(1)
        end
    end

    if success and decode then
        response = JSONDecode(response)
    end

    if success then
        return true, response
    else
        return false, response
    end
end

function System:setup_system()
    self.system_data = {}
    self.system_data.packages = {}

    self:download_core_packages()
    self:save()
end

function System:execute()
end

function System:save()
    self.system_disk:Write("terminal_system", self.system_data)
end

function System:shutdown()
    self:save()
    Microcontroller:Shutdown()
end

function System:has_system()
    return self.system_data and true
end

local new_system = System:new(GetPart("Disk"), GetPart("Modem"))
new_system:boot()
