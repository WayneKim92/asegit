--[[
Aseprite Git Integration Script (File-Centric with Auto-Move/Delete & Commit)
Features:
- Initialize Git for This File: Creates a subfolder, moves the file, deletes the original, and initializes Git.
  Checks and stops BEFORE confirmation if the file is ALREADY inside an existing Git repo. (⚠️ Use with caution!)
- Git Commit This File: Commits changes for the currently active Aseprite file.
--]]

-- Helper function to extract directory path
local function extractFolder(path)
  if not path then return nil end
  path = path:gsub("\\", "/")
  local match = path:match("^(.*)/[^/]+$")
  if not match and path:match("^[a-zA-Z]:/$") then return path end
  if not match and path:match("^/$") then return path end
  if not match and not path:match("/") then return nil end
  return match
end

-- Helper function to check if a path is a valid Git repository
local function folderIsValidGitRepo(path)
  if not path then return false end
  local gitDirPath = path:gsub("\\", "/") .. "/.git"
  local checkCmd
  if package.config:sub(1,1) == "\\" then
      checkCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', gitDirPath:gsub("/", "\\"))
  else
      checkCmd = string.format('[ -d "%s" ]', gitDirPath)
  end
  return (os.execute(checkCmd) == true or os.execute(checkCmd) == 0)
end

-- Helper function to run command in dir and get output
local function getCommandOutputInDir(directory, command)
  if not directory then return nil, "Directory not specified." end
  local fullCommand
  if package.config:sub(1,1) == "\\" then
    fullCommand = string.format('cd /d "%s" & %s', directory:gsub("/", "\\"), command)
  else
    fullCommand = string.format('cd "%s" && %s', directory, command)
  end
  local handle = io.popen(fullCommand)
  if handle then
    local output = handle:read("*a")
    local success, exitCode = handle:close()
    if success or (exitCode == 0) then
      return output
    else
      return nil, "Command failed (exit code: " .. tostring(exitCode) .. ")"
    end
  else
    return nil, "Failed to start command (io.popen failed)."
  end
end

-- Helper function to run command in dir, check success/failure
local function runCommandInDir(directory, command, actionName, suppressErrorAlert)
   if not directory then
       if not suppressErrorAlert then app.alert(actionName .. " failed: Directory not specified.") end
       return false
   end
  local fullCommand
  if package.config:sub(1,1) == "\\" then
    fullCommand = string.format('cd /d "%s" & %s', directory:gsub("/", "\\"), command)
  else
    fullCommand = string.format('cd "%s" && %s', directory, command)
  end
  local result = os.execute(fullCommand)
  local success = (result == true or result == 0)
  if not success and not suppressErrorAlert then
    app.alert(actionName .. " failed. Check console or ensure Git is installed and in PATH.")
  end
  return success
end

-- Helper function to create a directory
local function createDirectory(dirPath)
    local command
    if package.config:sub(1,1) == "\\" then
        command = string.format('mkdir "%s"', dirPath:gsub("/", "\\"))
    else
        command = string.format('mkdir -p "%s"', dirPath)
    end
    os.execute(command)
    local checkCmd
    if package.config:sub(1,1) == "\\" then
        checkCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', dirPath:gsub("/", "\\"))
    else
        checkCmd = string.format('[ -d "%s" ]', dirPath)
    end
    return (os.execute(checkCmd) == true or os.execute(checkCmd) == 0)
end

-- Helper function to get relative path
local function getRelativePath(basePath, fullPath)
  if not basePath or not fullPath then return nil end
  basePath = basePath:gsub("\\", "/")
  fullPath = fullPath:gsub("\\", "/")
  if basePath:sub(-1) ~= "/" then basePath = basePath .. "/" end
  if fullPath:lower():sub(1, #basePath) == basePath:lower() then
    return fullPath:sub(#basePath + 1)
  else
    return nil
  end
end


-- ========================================================================
-- == Command: Initialize Git Repository for the Current Single File ==
-- ========================================================================
local function initializeGitForCurrentFile() -- Renamed function to match title conceptually
  -- 1. Get Active Sprite and File Path
  local sprite = app.sprite
  if not sprite then app.alert("No active file is open."); return end
  local oldPath = sprite.filename
  if not oldPath or oldPath == "" then app.alert("The active file must be saved first."); return end

  local currentFileName = oldPath:match("([^/\\]+)$")
  local baseName = currentFileName:match("^(.-)%.ase?prite$")
  if not baseName or baseName == "" then baseName = currentFileName end
  local parentDir = extractFolder(oldPath)
  if not parentDir then app.alert("Error: Could not determine the directory of the current file."); return end

  -- 2. Define New Paths
  local newDir = parentDir:gsub("\\", "/") .. "/" .. baseName
  local newPath = newDir .. "/" .. currentFileName

  -- 3. Check if the CURRENT file's directory (or ancestors) is ALREADY a Git repo
  local existingRepoDir = nil
  local tempDir = parentDir
  while tempDir do
      if folderIsValidGitRepo(tempDir) then existingRepoDir = tempDir; break end
      local nextParentDir = extractFolder(tempDir)
      if not nextParentDir or nextParentDir == tempDir then break end
      tempDir = nextParentDir
  end

  if existingRepoDir then
      app.alert("The current file's directory ('" .. parentDir .. "') is already inside a Git repository located at:\n'" .. existingRepoDir .. "'.\n\nThis command cannot proceed.\nUse 'Git Commit This File' to commit changes within the existing repository.")
      return
  end

  -- 4. Confirmation Dialog
  local confirmation = app.alert{
    title = "Confirm File Move & Git Init",
    text = "This will attempt to:\n" ..
           "1. Create folder: '" .. newDir .. "'\n" ..
           "2. Save file copy to: '" .. newPath .. "'\n" ..
           "3. DELETE original file: '" .. oldPath .. "'\n" ..
           "4. Initialize Git repository in the new folder.\n\n" ..
           "⚠️ This action moves and deletes files. Proceed?",
    buttons = {"Yes, Move/Delete and Init", "Cancel"}
  }

  if confirmation ~= 1 then
    app.alert("Operation cancelled by user.")
    return
  end

  -- 5. Check if the target sub-directory exists as a plain folder
  local checkDirCmd
  if package.config:sub(1,1) == "\\" then checkDirCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', newDir:gsub("/", "\\"))
  else checkDirCmd = string.format('[ -d "%s" ]', newDir) end
  if (os.execute(checkDirCmd) == true or os.execute(checkDirCmd) == 0) then
      app.alert("Error: Target folder ('" .. newDir .. "') already exists but is not a Git repository.\nPlease check the folder, rename/remove it, or manage it manually.")
      return
  end

  -- If we reach here, the target directory does not exist. Create it.
  if not createDirectory(newDir) then app.alert("Error: Failed to create the target directory: '" .. newDir .. "'"); return end

  -- 6. Attempt to Save the File to the New Location
  sprite.filename = newPath
  app.command.SaveFile()
  local checkFileCmdAfterSave
   if package.config:sub(1,1) == "\\" then checkFileCmdAfterSave = string.format('if exist "%s" (exit 0) else (exit 1)', newPath:gsub("/", "\\"))
   else checkFileCmdAfterSave = string.format('[ -f "%s" ]', newPath) end
  local savedSuccessfully = (os.execute(checkFileCmdAfterSave) == true or os.execute(checkFileCmdAfterSave) == 0)
  if not savedSuccessfully then
    sprite.filename = oldPath
    app.alert("Error: Failed to save file to '" .. newPath .. "'.\nOperation aborted. Your file should still be at the original location:\n'" .. oldPath .. "'")
    os.execute(string.format('rmdir "%s"', newDir:gsub("/", "\\")))
    os.execute(string.format('rmdir "%s"', newDir))
    return
  end

  -- Attempt to delete the original file
  local originalFileDeleted = false
  local deleteWarning = nil
  local deleteCmd
  if package.config:sub(1,1) == "\\" then deleteCmd = string.format('del /F /Q "%s"', oldPath:gsub("/", "\\"))
  else deleteCmd = string.format('rm -f "%s"', oldPath) end
  local deleteResult = os.execute(deleteCmd)
  originalFileDeleted = (deleteResult == true or deleteResult == 0)
  if not originalFileDeleted then deleteWarning = "\n\nWARNING: Could not delete the original file at:\n'" .. oldPath .. "'"; print("Warning: Failed to delete original file: " .. oldPath) end

  -- 7. Initialize Git Repository in the new directory
  if runCommandInDir(newDir, 'git init', 'Initialize Git Repository') then
    local addCmd = string.format('git add "%s"', currentFileName:gsub('"', '\\"'))
    if runCommandInDir(newDir, addCmd, 'Git Add File') then
      local commitMsg = "Initial commit: Add " .. currentFileName
      local commitCmd = string.format('git commit -m "%s"', commitMsg:gsub('"', '\\"'))
      if runCommandInDir(newDir, commitCmd, 'Initial Commit') then
          local finalMessage = "Success!\nFile saved to: '" .. newPath .. "'\nGit repository initialized and file tracked."
          if deleteWarning then finalMessage = finalMessage .. deleteWarning
          elseif originalFileDeleted then finalMessage = finalMessage .. "\nOriginal file deleted." end
          app.alert(finalMessage)
      end
    end
  else
      local criticalErrorMsg = "CRITICAL ERROR: File was saved to '" .. newPath .. "', but failed to initialize Git repository."
      if originalFileDeleted then criticalErrorMsg = criticalErrorMsg .. "\nOriginal file WAS DELETED."
      elseif deleteWarning then criticalErrorMsg = criticalErrorMsg .. deleteWarning
      else criticalErrorMsg = criticalErrorMsg .. "\nOriginal file was NOT deleted." end
      criticalErrorMsg = criticalErrorMsg .. "\nPlease check the directory and your Git installation."
      app.alert(criticalErrorMsg)
  end
end


-- ========================================================================
-- == Command: Git Commit Current File ==
-- ========================================================================
local function gitCommitCurrentFile()
    -- 1. Get Active Sprite and File Path
    local sprite = app.sprite
    if not sprite then app.alert("No active file is open."); return end
    local currentFilePath = sprite.filename
    if not currentFilePath or currentFilePath == "" then app.alert("The active file must be saved first."); return end
    local currentFileName = currentFilePath:match("([^/\\]+)$")
    local currentDir = extractFolder(currentFilePath)
    if not currentDir then app.alert("Error: Could not determine the directory of the current file."); return end

    -- 2. Find Git Repository containing this file
    local repoDir = nil
    local tempDir = currentDir
    while tempDir do
        if folderIsValidGitRepo(tempDir) then repoDir = tempDir; break end
        local parentDir = extractFolder(tempDir)
        if not parentDir or parentDir == tempDir then break end
        tempDir = parentDir
    end
    if not repoDir then app.alert("Could not find a Git repository containing this file ('" .. currentFilePath .. "').\nHas it been initialized using 'Initialize Git for This File'?")
    return end -- Added user feedback for clarity

    -- 3. Get Relative Path
    local relativePath = getRelativePath(repoDir, currentFilePath)
    if not relativePath then
        if repoDir:gsub("\\", "/") == currentDir:gsub("\\", "/") then relativePath = currentFileName
        else app.alert("Error: Could not determine file's relative path within the repository '" .. repoDir .. "'."); return end
    end

    -- 4. Check for Unsaved Changes in Aseprite
    if sprite.is_modified then
        local saveConfirmation = app.alert{ title = "Unsaved Changes", text = "The current file has unsaved changes.\nSave them before committing?", buttons = {"Save and Continue", "Cancel Commit"} }
        if saveConfirmation == 1 then
            app.command.SaveFile()
             if sprite.is_modified then app.alert("Error: Failed to save changes. Please save manually and try committing again."); return end
        else app.alert("Commit cancelled."); return end
    end

    -- 5. Check Git Status for Changes
    local gitStatusCmd = string.format('git status --porcelain -- "%s"', relativePath:gsub('"', '\\"'))
    local statusOutput, statusErr = getCommandOutputInDir(repoDir, gitStatusCmd)
    if statusOutput == nil then app.alert("Failed to get Git status for the file.\nError: " .. (statusErr or "Unknown")); return end
    if statusOutput == "" then app.alert("No changes detected for '" .. currentFileName .. "' compared to the last commit."); return end

    -- Stage the file before commit dialog
    local addCmd = string.format('git add "%s"', relativePath:gsub('"', '\\"'))
    if not runCommandInDir(repoDir, addCmd, "Git Add File (Staging)") then app.alert("Failed to stage changes for the file. Commit aborted."); return end

    -- 6. Get Commit Message
    local dlg = Dialog("Git Commit: " .. currentFileName)
    dlg:entry{ id="message", label="Commit Message:", text="Update " .. currentFileName }
    dlg:button{ id="ok", text="Commit" }; dlg:button{ id="cancel", text="Cancel" }
    dlg:show()

    -- 7. Perform Commit
    local data = dlg.data
    if data.ok and data.message and data.message:match("%S") then
        local message = data.message:gsub('"', '\\"')
        local commitCmd = string.format('git commit -m "%s"', message)
        if runCommandInDir(repoDir, commitCmd, "Git Commit") then app.alert("Commit successful for '" .. currentFileName .. "'!")
        else app.alert("Commit failed for '" .. currentFileName .. "'. Check console for details. Perhaps there were conflicts or other issues.") end
    elseif data.ok then app.alert("Commit cancelled: Message cannot be empty.")
    else app.alert("Commit cancelled.") end
end


-- ======================================================
-- == Register Commands ==
-- ======================================================
function init(plugin)
  local scriptGroup = "file_scripts"

  plugin:newCommand{
    id = "MoveAndInitGitForFile",
    title = "Initialize Git for This File", -- <<< Changed Title
    group = scriptGroup,
    onclick = initializeGitForCurrentFile -- Changed function name to match title
  }

  plugin:newCommand{
    id = "GitCommitCurrentFile",
    title = "Git Commit This File",
    group = scriptGroup,
    onclick = gitCommitCurrentFile
  }
end₩