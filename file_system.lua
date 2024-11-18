local ServerScriptService = game:GetService("ServerScriptService")
local Calculation = require(ServerScriptService.Modules.Calculation)

export type primitive = string | number | boolean | {primitive} | {[primitive]: primitive}
export type permissions = {
	read: boolean?;
	write: boolean?;
}
export type attributes = {
	metadata: {[primitive]: primitive}?;
	permissions: ({
		owner: "system" | number;
		userPermissions: { [number]: permissions; }?
	} & permissions)?
}

export type Directory = {
	kind: "directory";
	contents: {
		[string]: FileNode;
	};
	attributes: attributes?;
}
export type File = {
	kind: "file";
	contents: string;
	attributes: attributes?;
}
export type Device<T> = {
	kind: "device";
	device: T;
	attributes: attributes?;
}
export type Link = {
	kind: "link";
	target: string;
	attributes: attributes?;
}

export type Root = {
	kind: "root";
	root: Directory;
	attributes: attributes?;

	pwd: string;
}

export type FileNode = Directory | File | Link | Root | Device<any>;

local FileSystem = {}
FileSystem.__index = FileSystem
FileSystem.separator = "/"

local RawFileSystem = {}

function RawFileSystem.Device<T>(device: T, attributes): Device<T>
	return table.freeze({
		kind = "device";
		device = device;
		attributes = attributes;
	})
end

function RawFileSystem.Link(pathname: string, attributes): Link
	return table.freeze({
		kind = "link";
		target = pathname;
		attributes = attributes;
	})
end

function RawFileSystem.File(contents: string, attributes): File
	return table.freeze({
		kind = "file";
		contents = contents;
		attributes = attributes;
	})
end

function RawFileSystem.Directory(contents, attributes, readonly: boolean?): Directory
	return table.freeze({
		kind = "directory";
		contents = if readonly then table.freeze(table.clone(contents)) else contents;
		attributes = attributes;
	})
end

function RawFileSystem.Root(root: Directory, attributes): Root
	return table.freeze({
		kind = "root";
		root = root;

		pwd = FileSystem.separator;
		attributes = attributes;
	})
end

local NO_SUCH_FILE_ERR = "No such file or directory"
local PATH_ALREADY_EXISTS_ERR = "Path already exists"
local NOT_A_DIRECTORY_ERR = "Not a directory"
local NOT_A_FILE_ERR = "Not a file"
local IS_A_DIRECTORY_ERR = "Is a directory"
local IS_A_FILE_ERR = "Is a file"

local INVALID_NODE_ERR = "Cannot write invalid FileNode"
local INVALID_PATH_ERR = "Invalid path"
local INVALID_CONTENTS_ERR = "Invalid contents"
local CIRCULAR_LINK_ERR = "Links cannot be circular"

local PERM_NO_READ_ERR = "Not allowed to read file"
local PERM_NO_WRITE_ERR = "Not allowed to modify file"

local function _resolve(root: Root, path: {string}): {string}
	local finalPath = table.create(#path)

	-- If the first segment isn't blank (not at root) or the first segment is a ., we need to resolve the current directory
	if path[1] ~= "" or path[1] == "." then
		-- Grab the current working directory and split it, then append the current path onto the end
		local pwd = FileSystem.pwd(root)
		local pwdPath = string.split(pwd, FileSystem.separator)
		path = table.move(path, 1, #path, #pwdPath + 1, pwdPath)
	end

	-- For each path segment
	for index, segment in ipairs(path) do
		if segment == ".." then
			-- If the path segment is the parent directory key, we remove the current path
			table.remove(finalPath, #finalPath)
		elseif segment ~= "." and segment ~= "" then
			-- If the path segment is a . or is blank (e.g. /dir//a or /dir/./././a) we ignore it
			-- Otherwise we insert the segment into the final results
			table.insert(finalPath, segment)
		end
	end

	-- Ensure the path will be at the root
	if finalPath[1] ~= "" then
		table.insert(finalPath, 1, "")
	end
	return finalPath
end

local function _join(paths: {string}): string
	-- If the path is a single blank string, return the root directory path, otherwise join by the separator
	if not paths[2] and paths[1] == "" then return FileSystem.separator end
	return table.concat(paths, FileSystem.separator)
end

local function _checkPermission(node: FileNode, permission)
	local attributes = node.attributes
	local permissions = attributes and attributes.permissions
	if permissions then
		-- If permission is not met, cancel
		if not permissions[permission] then return false end
	end
	return true
end

type OperationOptions = {
	ignoreLinks: boolean?;
	ignorePermissions: boolean?;
}

local _read;
local function _readLink(root: Root, link: Link, options: OperationOptions?)
	local linkOptions = table.clone(options or {})
	linkOptions.ignoreLinks = true
	
	local linksSeen = {[link] = true}

	local linkTarget: FileNode? = link
	while linkTarget and linkTarget.kind == "link" do
		local target = linkTarget.target
		linkTarget = target and _read(root, target, linkOptions)

		-- If the link has been seen, the link is circular, so cancel
		if linksSeen[linkTarget] then return nil end
		linksSeen[linkTarget] = true
	end
	return linkTarget
end


-- Raw read/write functions
function _read(root: Root, pathname: string, options: OperationOptions?): FileNode?
	-- Resolve the full path
	local path = _resolve(root, FileSystem.split(pathname))
	
	-- Grab the root's root system
	local currentNode: FileNode?
	
	-- When a node is traversed
	local function onNode(node: FileNode?)
		if node then
			-- Check permissions
			if not (options and options.ignorePermissions) then
				-- Enforce node permissions
				assert(_checkPermission(node, "read"), PERM_NO_READ_ERR)
			end

			-- Follow links
			if node.kind == "link" and not (options and options.ignoreLinks) then
				node = _readLink(root, node, options)
				assert(node, CIRCULAR_LINK_ERR)
				return onNode(node)
			end
		end
		
		-- Update current node
		currentNode = node
	end
	
	-- Receive root node then root node
	onNode(root)
	onNode(root.root)
	
	-- For each segment in the path, go a level deeper
	for _, segment in ipairs(path) do
		if segment == "" or segment == "." then continue end
		
		assert(currentNode, NOT_A_DIRECTORY_ERR)
		assert(type(currentNode) == "table", NOT_A_DIRECTORY_ERR)
		assert(currentNode.kind == "directory", NOT_A_DIRECTORY_ERR)
		
		-- Process the next node
		onNode(currentNode.contents[segment])
	end

	return currentNode
end

local function _write(root: Root, pathname: string, value: FileNode?, options: OperationOptions?)
	-- Check arguments
	assert(type(pathname) == "string", "Path is not a string")

	if value then
		assert(type(value) == "table" and type(value.kind) == "string", INVALID_NODE_ERR)
	end

	-- Separate the parent directory and the file name
	local parentPath = FileSystem.parentdir(pathname)
	local fileName = FileSystem.filename(pathname)
	
	-- Read the parent directory
	local directory = _read(root, parentPath, options)
	
	-- Ensure that the directory exists
	assert(type(directory) == "table" and directory.kind == "directory", NOT_A_DIRECTORY_ERR)
	--assert(value.kind == "file" or type(directory.contents[fileName]) == "nil", PATH_ALREADY_EXISTS_ERR)

	-- Enforce writability on parent directory
	assert(not table.isfrozen(directory.contents), PERM_NO_READ_ERR)
	
	-- Check permissions
	local target = directory.contents[fileName]
	if not (options and options.ignorePermissions) then
		-- Enforce node permissions on target, if it exists
		if target then
			assert(_checkPermission(target, "write"), PERM_NO_READ_ERR)
		end
	end
	
	-- Write the file
	directory.contents[fileName] = value
end

function FileSystem:exists(pathname: string): boolean
	if not _read(self, pathname, { ignoreLinks = true; }) then
		return false
	end
	return true
end

function FileSystem:resolve(pathname: string): string
	return _join(_resolve(self, FileSystem.split(pathname)))
end

function FileSystem.split(pathname: string): {string}
	assert(type(pathname) == "string", INVALID_PATH_ERR)
	
	return string.split(pathname, FileSystem.separator)
end

function FileSystem.join(...: string): string
	local redundantDirectoryPattern = string.format("(%s.)+", FileSystem.separator)
	local repetitiveSeparatorPattern = string.format("%s+", string.rep(FileSystem.separator, 2))

	local path = _join(table.pack(...))
	return string.gsub(string.gsub(path, redundantDirectoryPattern, FileSystem.separator), repetitiveSeparatorPattern, FileSystem.separator)
end

function FileSystem.parentdir(pathname: string): string
	local path = FileSystem.split(pathname)
	table.remove(path, #path)
	return _join(path)
end

function FileSystem.filename(pathname: string): string
	local path = FileSystem.split(pathname)
	return path[#path]
end

function FileSystem:chdir(pathname: string): string
	local pwd = self:resolve(pathname)
	self.pwd = pwd
	return pwd
end
function FileSystem:pwd(): string
	return self.pwd or FileSystem.separator
end

function FileSystem:writefile(filepath: string, contents: string)
	assert(type(contents) == "string", INVALID_CONTENTS_ERR)
	
	_write(self, filepath, RawFileSystem.File(contents))
end
function FileSystem:readfile(filepath: string): string
	local file = _read(self, filepath)
	assert(file.kind ~= "directory", IS_A_DIRECTORY_ERR)
	return (assert(file.kind == "file" and file.contents, NOT_A_FILE_ERR))
end
function FileSystem:readdir(pathname: string): {string}
	local directory = _read(self, pathname)
	assert(directory.kind ~= "file", IS_A_FILE_ERR)
	assert(type(directory.contents) == "table", NOT_A_DIRECTORY_ERR)

	local fileList = {}
	for filename, _file in directory.contents do
		table.insert(fileList, filename)
	end
	return fileList
end

function FileSystem:mkdir(pathname: string)
	_write(self, pathname, RawFileSystem.Directory({}))
end
function FileSystem:mklink(linkName: string, targetName: string)
	_write(self, linkName, RawFileSystem.Link(self:resolve(targetName)))
end

function FileSystem:copy(pathnameFrom: string, pathnameTo: string)
	local node = _read(self, pathnameFrom, { ignoreLinks = true; })
	assert(node, NO_SUCH_FILE_ERR)
	_write(self, pathnameTo, Calculation:CopyTable(node))
end
function FileSystem:moveMerge(pathnameFrom: string, pathnameTo: string)
	local source = _read(self, pathnameFrom)
	local destination = _read(self, pathnameTo)
	
	-- If the destination doesn't exist or is a file, we rename directly
	if not destination or source.kind == "file" then
		-- If the target has a trailing slash and the source doesn't, we want to try to do a move *into* the target
		if string.sub(pathnameFrom, #pathnameFrom) ~= "/" and string.sub(pathnameTo, #pathnameTo) == "/" then
			local intoPath = FileSystem.join(pathnameTo, FileSystem.filename(pathnameFrom))
			if self:exists(intoPath) then
				pathnameTo = intoPath
			end
		end
		
		-- Rename the source to the destination directly
		return self:rename(pathnameFrom, pathnameTo)
	end
	
	if source.kind ~= "directory" then return end

	for index, value in source do
		local sourceFile = FileSystem.join(pathnameFrom, index)
		local targetFile = FileSystem.join(pathnameTo, index)
		self:moveMerge(sourceFile, targetFile)
	end
end

function FileSystem:rename(pathnameFrom: string, pathnameTo: string | nil)
	if pathnameTo then
		_write(self, pathnameTo, _read(self, pathnameFrom, { ignoreLinks = true; }))
	end
	_write(self, pathnameFrom, nil)
end
function FileSystem:unlink(pathname: string)
	self:rename(pathname, nil)
end

-- Readonly attributes
local ATTRIBUTES_READONLY = table.freeze({
	permissions = table.freeze({
		owner = "system";
		read = true;
		write = false;
	});
})

-- No access attributes
local ATTRIBUTES_NOACCESS = table.freeze({
	permissions = table.freeze({
		owner = "system";
		read = false;
		write = false;
	});
})

RawFileSystem.SYSTEM_READONLY = ATTRIBUTES_READONLY
RawFileSystem.SYSTEM_NOACCESS = ATTRIBUTES_NOACCESS

function FileSystem.new(source: (Root | Directory)?)
	local directory = if source and source.kind == "directory" then source else RawFileSystem.Directory({}, ATTRIBUTES_READONLY)
	local sourceRoot = if source and source.kind == "root" then source else RawFileSystem.Root(directory, ATTRIBUTES_READONLY)

	return table.freeze(setmetatable(table.clone(sourceRoot), FileSystem))
end
export type FileSystem = typeof(FileSystem.new())

function RawFileSystem:read(root: Root, pathname: string, options)
	return _read(root, pathname, options)
end
function RawFileSystem:write(root: Root, pathname: string, node: FileNode, options)
	return _write(root, pathname, node, options)
end
function RawFileSystem:readlink(root: Root, link: Link, options)
	return _readLink(root, link, options)
end

return table.freeze(FileSystem), table.freeze(RawFileSystem)
