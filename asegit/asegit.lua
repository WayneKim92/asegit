--[[
Aseprite Git Integration Script (File-Centric with Auto-Move/Delete)
Feature:
- Creates a subfolder named after the active file, saves the file into it,
  deletes the original file, and initializes a dedicated Git repository for that file.
  (⚠️ Use with caution!)
--]]

-- Helper function to extract directory path from a full file path
local function extractFolder(path)
  if not path then return nil end
  path = path:gsub("\\", "/")
  return path:match("^(.*)/[^/]+$")
end

-- Helper function to check if a path is a valid Git repository
local function folderIsValidGitRepo(path)
  if not path then return false end
  local gitPath = path:gsub("\\", "/") .. "/.git"
  local command
  if package.config:sub(1,1) == "\\" then
    command = string.format('if exist "%s\\" (exit 0) else (exit 1)', gitPath:gsub("/", "\\"))
  else
    command = string.format('[ -d "%s" ]', gitPath)
  end
  local result = os.execute(command)
  return result == true or result == 0
end

-- Helper function to run a shell command in a specific directory and capture output
-- (Kept as it's used for git status check within moveAndInitGitForCurrentFile)
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

-- Helper function to run a shell command in a specific directory, checking only success/failure
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

-- Removed getRelativePath function as it's no longer needed

-- ========================================================================
-- == Command: Move Current File to Subfolder & Initialize Git ==
-- ========================================================================
local function moveAndInitGitForCurrentFile()
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

  -- 3. Confirmation Dialog
  local confirmation = app.alert{
    title = "Confirm File Move & Git Init",
    text = "This will:\n" ..
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

  -- 4. Check if the target directory already exists and is a Git repo
  if folderIsValidGitRepo(newDir) then
      local checkFileCmd
      if package.config:sub(1,1) == "\\" then
          checkFileCmd = string.format('if exist "%s" (exit 0) else (exit 1)', newPath:gsub("/", "\\"))
      else
          checkFileCmd = string.format('[ -f "%s" ]', newPath)
      end
      if (os.execute(checkFileCmd) == true or os.execute(checkFileCmd) == 0) then
          local gitStatusCmd = string.format('git status --porcelain -- "%s"', currentFileName:gsub('"', '\\"'))
          -- Use getCommandOutputInDir here to check status
          local statusOutput, _ = getCommandOutputInDir(newDir, gitStatusCmd)
          if statusOutput ~= nil and statusOutput ~= "" then
              app.alert("It seems this file already exists in the target Git repository ('" .. newDir .. "') and is tracked.")
          else
               app.alert("File already exists in the target folder ('" .. newDir .. "'), which is a Git repo, but isn't tracked. Adding it now.")
               if runCommandInDir(newDir, string.format('git add "%s"', currentFileName:gsub('"', '\\"')), "Git Add File") then
                   runCommandInDir(newDir, string.format('git commit -m "%s"', ("Add " .. currentFileName):gsub('"', '\\"')), "Git Commit File")
                   app.alert("File added and committed to the existing repository in '" .. newDir .. "'.")
               end
          end
      else
          app.alert("Error: Target folder ('" .. newDir .. "') is already a Git repository, but the file '" .. currentFileName .. "' is not found inside it. Cannot proceed.")
      end
      return
  end

  -- 5. Create the new directory
  local checkDirCmd
  if package.config:sub(1,1) == "\\" then
      checkDirCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', newDir:gsub("/", "\\"))
  else
      checkDirCmd = string.format('[ -d "%s" ]', newDir)
  end
  if (os.execute(checkDirCmd) == true or os.execute(checkDirCmd) == 0) then
      app.alert("Error: Target folder ('" .. newDir .. "') already exists but is not a Git repository. Please check the folder and try again.")
      return
  end

  if not createDirectory(newDir) then
      app.alert("Error: Failed to create the target directory: '" .. newDir .. "'")
      return
  end

  -- 6. Attempt to Save the File to the New Location
  sprite.filename = newPath
  app.command.SaveFile()

  -- Verification: Check if file exists at new path
  local checkFileCmdAfterSave
   if package.config:sub(1,1) == "\\" then
       checkFileCmdAfterSave = string.format('if exist "%s" (exit 0) else (exit 1)', newPath:gsub("/", "\\"))
   else
       checkFileCmdAfterSave = string.format('[ -f "%s" ]', newPath)
   end
  local savedSuccessfully = (os.execute(checkFileCmdAfterSave) == true or os.execute(checkFileCmdAfterSave) == 0)

  if not savedSuccessfully then
    -- Attempt recovery
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
  if package.config:sub(1,1) == "\\" then
      deleteCmd = string.format('del "%s"', oldPath:gsub("/", "\\"))
  else
      deleteCmd = string.format('rm "%s"', oldPath)
  end
  local deleteResult = os.execute(deleteCmd)
  originalFileDeleted = (deleteResult == true or deleteResult == 0)
  if not originalFileDeleted then
      deleteWarning = "\n\nWARNING: Could not delete the original file at:\n'" .. oldPath .. "'"
      print("Warning: Failed to delete original file: " .. oldPath)
  end

  -- 7. Initialize Git Repository in the new directory
  if runCommandInDir(newDir, 'git init', 'Initialize Git Repository') then
    local addCmd = string.format('git add "%s"', currentFileName:gsub('"', '\\"'))
    if runCommandInDir(newDir, addCmd, 'Git Add File') then
      local commitMsg = "Initial commit: Add " .. currentFileName
      local commitCmd = string.format('git commit -m "%s"', commitMsg:gsub('"', '\\"'))
      if runCommandInDir(newDir, commitCmd, 'Initial Commit') then
          local finalMessage = "Success!\nFile saved to: '" .. newPath .. "'\nGit repository initialized and file tracked."
          if deleteWarning then
              finalMessage = finalMessage .. deleteWarning
          elseif originalFileDeleted then
               finalMessage = finalMessage .. "\nOriginal file deleted."
          end
          app.alert(finalMessage)
      end
    end
  else
      local criticalErrorMsg = "CRITICAL ERROR: File was saved to '" .. newPath .. "', but failed to initialize Git repository."
      if originalFileDeleted then
          criticalErrorMsg = criticalErrorMsg .. "\nOriginal file WAS DELETED."
      elseif deleteWarning then
          criticalErrorMsg = criticalErrorMsg .. deleteWarning
      else
           criticalErrorMsg = criticalErrorMsg .. "\nOriginal file was NOT deleted."
      end
      criticalErrorMsg = criticalErrorMsg .. "\nPlease check the directory and your Git installation."
      app.alert(criticalErrorMsg)
  end
end

-- Removed showCurrentFileGitLogDialog function

-- ======================================================
-- == Register Commands ==
-- ======================================================
function init(plugin)
  local scriptGroup = "file_scripts"

  -- Command to move file to subfolder and initialize Git
  plugin:newCommand{
    id = "MoveAndInitGitForFile",
    title = "Move File & Init Git", -- Keep title descriptive
    group = scriptGroup,
    onclick = moveAndInitGitForCurrentFile
  }

  -- Removed registration for "asegit" (View File Git Log) command
end