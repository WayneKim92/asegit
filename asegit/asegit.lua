-- ======================================================
-- == Helper Functions ==
-- ======================================================
-- Helper function to extract directory path
local function extractFolder(path)
    if not path then
        return nil
    end
    path = path:gsub("\\", "/")
    local match = path:match("^(.*)/[^/]+$")
    if not match and path:match("^[a-zA-Z]:/$") then
        return path
    end
    if not match and path:match("^/$") then
        return path
    end
    if not match and not path:match("/") then
        return nil
    end
    return match
end

-- Helper function to check if a path is a valid Git repository
local function folderIsValidGitRepo(path)
    if not path then
        return false
    end
    local gitDirPath = path:gsub("\\", "/") .. "/.git"
    local checkCmd
    if package.config:sub(1, 1) == "\\" then
        checkCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', gitDirPath:gsub("/", "\\"))
    else
        checkCmd = string.format('[ -d "%s" ]', gitDirPath)
    end
    -- os.execute의 반환값은 성공 시 0(POSIX) 또는 true(Windows)일 수 있음
    local result = os.execute(checkCmd)
    return (result == true or result == 0)
end

-- Helper function to run command in dir and get output
local function getCommandOutputInDir(directory, command)
    if not directory then
        return nil, "Directory not specified."
    end
    local fullCommand
    if package.config:sub(1, 1) == "\\" then
        fullCommand = string.format('cd /d "%s" & %s', directory:gsub("/", "\\"), command)
    else
        fullCommand = string.format('cd "%s" && %s', directory, command)
    end
    local handle = io.popen(fullCommand)
    if handle then
        local output = handle:read("*a")
        -- io.popen().close() returns (bool success | nil, string "exit" | "signal", int exitCode | signalNumber)
        local success, reason, code = handle:close()
        if success and code == 0 then -- Check for successful execution AND exit code 0
            return output
        elseif not success then
            return nil, "Command execution failed (popen error)."
        else
            return nil, "Command failed (exit code: " .. tostring(code) .. ")"
        end
    else
        return nil, "Failed to start command (io.popen failed)."
    end
end

-- Helper function to run command in dir, check success/failure
local function runCommandInDir(directory, command, actionName, suppressErrorAlert)
    if not directory then
        if not suppressErrorAlert then
            app.alert(actionName .. " failed: Directory not specified.")
        end
        return false
    end
    local fullCommand
    if package.config:sub(1, 1) == "\\" then
        fullCommand = string.format('cd /d "%s" & %s', directory:gsub("/", "\\"), command)
    else
        fullCommand = string.format('cd "%s" && %s', directory, command)
    end
    local result = os.execute(fullCommand)
    local success = (result == true or result == 0)
    if not success and not suppressErrorAlert then
        -- Split error into multiple alerts
        app.alert(actionName .. " failed.")
        app.alert("Check console or ensure Git is installed and in PATH.")
    end
    return success
end

-- Helper function to create a directory
local function createDirectory(dirPath)
    local command
    if package.config:sub(1, 1) == "\\" then
        command = string.format('mkdir "%s"', dirPath:gsub("/", "\\"))
    else
        command = string.format('mkdir -p "%s"', dirPath)
    end
    os.execute(command) -- mkdir 실행 시도
    -- 생성 확인
    local checkCmd
    if package.config:sub(1, 1) == "\\" then
        checkCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', dirPath:gsub("/", "\\"))
    else
        checkCmd = string.format('[ -d "%s" ]', dirPath)
    end
    local checkResult = os.execute(checkCmd)
    return (checkResult == true or checkResult == 0)
end

-- Helper function to get relative path
local function getRelativePath(basePath, fullPath)
    if not basePath or not fullPath then
        return nil
    end
    basePath = basePath:gsub("\\", "/")
    fullPath = fullPath:gsub("\\", "/")
    if basePath:sub(-1) ~= "/" then
        basePath = basePath .. "/"
    end
    -- Case-insensitive comparison for Windows paths compatibility if needed, but usually git handles it.
    -- Using lower() for basic robustness.
    if fullPath:lower():startswith(basePath:lower()) then
        return fullPath:sub(#basePath + 1)
    else
        -- Handle cases where base path might be slightly different (e.g. trailing slash)
        -- This part might need more robust logic depending on expected inputs
        if basePath == fullPath:match("^(.*)/[^/]+$") .. "/" then
            return fullPath:match("([^/\\]+)$")
        end
        return nil -- Indicate path is not relative or error
    end
end

-- 임시 파일 경로 생성 (간단한 예시)
local function getTemporaryFilePath(baseName, commitHash, extension)
    local tmpDir
    -- OS별 임시 디렉토리 경로 확인 (더 견고한 방법 필요 시 라이브러리 사용 고려)
    if package.config:sub(1, 1) == "\\" then
        tmpDir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    else
        tmpDir = os.getenv("TMPDIR") or "/tmp"
    end
    -- 폴더가 없으면 생성 시도 (createDirectory 함수 재사용)
    createDirectory(tmpDir) -- createDirectory는 이미 존재하면 실패하지 않아야 함

    -- 파일 이름 생성 (중복 가능성 최소화)
    local safeBaseName = baseName:gsub("[^a-zA-Z0-9_.-]", "_") -- 파일명에 안전하지 않은 문자 제거
    local shortHash = commitHash:sub(1, 7) -- 짧은 해시 사용
    local timestamp = os.time()
    -- 경로 구분자 확인
    local sep = (package.config:sub(1, 1) == "\\") and "\\" or "/"

    -- !!!!! 수정: 파일 이름 앞에 "TEMP_" 추가 !!!!!
    return string.format("%s%sTEMP_%s_%s_%s.%s", tmpDir, sep, safeBaseName, shortHash, timestamp, extension)
end

-- ========================================================================
-- == Command: Initialize Git Repository for the Current Single File ==
-- ========================================================================
local function initializeGitForCurrentFile()
    -- 1. Get Active Sprite and File Path
    local sprite = app.sprite
    if not sprite then
        app.alert("No active file is open.");
        return
    end
    local oldPath = sprite.filename
    if not oldPath or oldPath == "" then
        app.alert("The active file must be saved first.");
        return
    end

    local currentFileName = oldPath:match("([^/\\]+)$")
    if not currentFileName then
        app.alert("Error: Could not extract filename.");
        return
    end -- 파일 이름 추출 실패 처리

    local baseName = currentFileName:match("^(.-)%.[^.]+$") -- 확장자 제거 개선
    if not baseName or baseName == "" then
        baseName = currentFileName
    end -- 확장자가 없는 경우 파일명 사용

    local parentDir = extractFolder(oldPath)
    if not parentDir then
        app.alert("Error: Could not determine the directory of the current file.");
        return
    end

    -- 2. Define New Paths
    local newDir = parentDir:gsub("\\", "/") .. "/" .. baseName
    local newPath = newDir .. "/" .. currentFileName

    -- 3. Check if the CURRENT file's directory ITSELF is ALREADY a Git repo
    --    (MODIFIED: Only checks the immediate parent directory, not ancestors)
    --    WARNING: This does NOT prevent creating nested repos if an ANCESTOR is a repo.
    if folderIsValidGitRepo(parentDir) then
        -- Split message into multiple alerts
        app.alert("The directory containing this file ('" .. parentDir .. "') is already a Git repository.")
        app.alert("This command ('Initialize Git for This File') cannot proceed here.")
        app.alert("Use 'Git Commit This File' to commit changes within this existing repository.")
        return
    end

    -- 4. Confirmation Dialog
    -- 4. Confirmation Dialog (Split into multiple alerts - English)
    -- Inform the user about the upcoming actions sequentially (each has an OK button)
    app.alert("This command will attempt the following actions:")
    app.alert("1. Create a new subfolder named:\n'" .. baseName .. "'")
    app.alert("2. Save a copy of the current file into that subfolder:\n'" .. newPath .. "'") -- Assumes newPath is defined earlier
    app.alert("3. DELETE the original file from:\n'" .. oldPath .. "'") -- Assumes oldPath is defined earlier
    app.alert("4. Initialize a Git repository in the new subfolder:\n'" .. newDir .. "'") -- Assumes newDir is defined earlier

    -- Final confirmation prompt with Yes/Cancel buttons
    local confirmation = app.alert {
        title = "Confirm Action",
        text = "Do you want to proceed with these actions?",
        buttons = {"Yes, Proceed", "Cancel"}
    }

    -- Check the user's choice (1 = Yes, Proceed)
    if confirmation ~= 1 then
        app.alert("Operation cancelled by user.")
        return
    end

    -- 5. Check if the target sub-directory exists as a plain folder
    local checkDirCmd
    if package.config:sub(1, 1) == "\\" then
        checkDirCmd = string.format('if exist "%s\\" (exit 0) else (exit 1)', newDir:gsub("/", "\\"))
    else
        checkDirCmd = string.format('[ -d "%s" ]', newDir)
    end
    local dirExistsResult = os.execute(checkDirCmd)
    if (dirExistsResult == true or dirExistsResult == 0) then
        -- Check if it's also a Git repo already (unlikely given step 3, but for completeness)
        if folderIsValidGitRepo(newDir) then
            app.alert("Error: The target folder '" .. baseName .. "' already exists and is a Git repository.")
            app.alert("Please manage it manually or use 'Git Commit This File'.")
        else
            app.alert("Error: A folder named '" .. baseName .. "' already exists but is not a Git repository.")
            app.alert("Please check the folder, rename/remove it, or manage it manually.")
        end
        return
    end

    -- Create the target directory
    if not createDirectory(newDir) then
        app.alert("Error: Failed to create the target directory '" .. newDir .. "'.");
        return
    end

    -- 6. Attempt to Save the File to the New Location
    -- Store old filename before changing it
    local originalSpriteFilename = sprite.filename
    sprite.filename = newPath
    -- Use try-catch equivalent or check sprite state after save command
    app.command.SaveFile()

    -- Verify file exists at new location AFTER saving
    local checkFileCmdAfterSave
    if package.config:sub(1, 1) == "\\" then
        checkFileCmdAfterSave = string.format('if exist "%s" (exit 0) else (exit 1)', newPath:gsub("/", "\\"))
    else
        checkFileCmdAfterSave = string.format('[ -f "%s" ]', newPath)
    end
    local savedSuccessfullyResult = os.execute(checkFileCmdAfterSave)
    local savedSuccessfully = (savedSuccessfullyResult == true or savedSuccessfullyResult == 0)

    if not savedSuccessfully then
        -- Revert filename in Aseprite if save failed
        sprite.filename = originalSpriteFilename
        app.alert("Error: Failed to save the file to the new location: " .. newPath)
        app.alert("Operation aborted.")
        app.alert("Your file should still be at its original location: " .. originalSpriteFilename)
        -- Attempt to remove the newly created (but empty or incomplete) directory
        local rmdirCmd
        if package.config:sub(1, 1) == "\\" then
            rmdirCmd = string.format('rmdir /S /Q "%s"', newDir:gsub("/", "\\")) -- Use /S /Q for non-empty dirs
        else
            rmdirCmd = string.format('rm -rf "%s"', newDir)
        end
        os.execute(rmdirCmd)
        return
    end

    -- Attempt to delete the original file (now that the new one is saved)
    local originalFileDeleted = false
    local deleteFailed = false -- Flag for deletion failure
    local deleteCmd
    if package.config:sub(1, 1) == "\\" then
        deleteCmd = string.format('del /F /Q "%s"', oldPath:gsub("/", "\\"))
    else
        deleteCmd = string.format('rm -f "%s"', oldPath)
    end
    local deleteResult = os.execute(deleteCmd)
    originalFileDeleted = (deleteResult == true or deleteResult == 0)
    if not originalFileDeleted then
        deleteFailed = true
        print("Warning: Failed to delete original file: " .. oldPath .. " (Result: " .. tostring(deleteResult) .. ")")
    end

    -- 7. Initialize Git Repository in the new directory
    if runCommandInDir(newDir, 'git init', 'Initialize Git Repository') then
        -- Use relative path for git add inside the new repo
        local addCmd = string.format('git add "%s"', currentFileName:gsub('"', '\\"'))
        if runCommandInDir(newDir, addCmd, 'Git Add File') then
            local commitMsg = "Initial commit: Add " .. currentFileName
            local commitCmd = string.format('git commit -m "%s"', commitMsg:gsub('"', '\\"'))
            if runCommandInDir(newDir, commitCmd, 'Initial Commit') then
                -- Show success message using multiple alerts
                app.alert("Success!")
                app.alert("File saved to new subfolder: " .. newDir)
                app.alert("Git repository initialized and file tracked.")
                if deleteFailed then
                    app.alert("WARNING: Could not automatically delete the original file at: " .. oldPath)
                    app.alert("Please delete it manually if desired.")
                elseif originalFileDeleted then
                    app.alert("Original file deleted from: " .. oldPath)
                end
                -- Refresh file browser if possible/needed (Aseprite API specific)
                -- app.refresh() or similar might be useful here if available
            else
                -- Commit failed after successful add
                app.alert("CRITICAL ERROR:")
                app.alert("Git repository initialized and file added, but the initial commit failed.")
                if originalFileDeleted then
                    app.alert("Original file WAS DELETED.")
                elseif deleteFailed then
                    app.alert("WARNING: Could not delete the original file.")
                else
                    app.alert("Original file was NOT deleted.")
                end
                app.alert("Please check the repository status manually in: " .. newDir)
            end
        else
            -- Add failed after successful init
            app.alert("CRITICAL ERROR:")
            app.alert("Git repository initialized, but failed to add the file.")
            if originalFileDeleted then
                app.alert("Original file WAS DELETED.")
            elseif deleteFailed then
                app.alert("WARNING: Could not delete the original file.")
            else
                app.alert("Original file was NOT deleted.")
            end
            app.alert("Please check the repository status manually in: " .. newDir)
        end
    else
        -- Git init failed
        app.alert("CRITICAL ERROR:")
        app.alert("File was saved to its new location, but failed to initialize Git repository in: " .. newDir)
        if originalFileDeleted then
            app.alert("Original file WAS DELETED.")
        elseif deleteFailed then
            app.alert("WARNING: Could not delete the original file.")
        else
            app.alert("Original file was NOT deleted.")
        end
        app.alert("Please check your Git installation and PATH environment variable.")
        app.alert("The new file exists at: " .. newPath)
        app.alert("The new directory exists at: " .. newDir)
    end
end

-- ========================================================================
-- == Command: Git Commit Current File ==
-- ========================================================================
local function gitCommitCurrentFile()
    -- 1. Get Active Sprite and File Path
    local sprite = app.sprite
    if not sprite then
        app.alert("No active file is open.");
        return
    end
    local currentFilePath = sprite.filename
    if not currentFilePath or currentFilePath == "" then
        app.alert("The active file must be saved first.");
        return
    end
    local currentFileName = currentFilePath:match("([^/\\]+)$")
    if not currentFileName then
        app.alert("Error: Could not extract filename.");
        return
    end

    local currentDir = extractFolder(currentFilePath)
    if not currentDir then
        app.alert("Error: Could not determine the directory of the current file.");
        return
    end

    -- 2. Find Git Repository containing this file (Searches upwards)
    local repoDir = nil
    local tempDir = currentDir
    while tempDir do
        if folderIsValidGitRepo(tempDir) then
            -- Check if .git is a directory (standard repo) or a file (submodule/worktree indicator)
            local gitPath = tempDir:gsub("\\", "/") .. "/.git"
            local checkGitTypeCmd
            if package.config:sub(1, 1) == "\\" then
                checkGitTypeCmd = string.format(
                    'if exist "%s\\" (echo directory) else (if exist "%s" (echo file) else (echo notfound))',
                    gitPath:gsub("/", "\\"), gitPath:gsub("/", "\\"))
            else
                checkGitTypeCmd = string.format(
                    'if [ -d "%s" ]; then echo directory; elif [ -f "%s" ]; then echo file; else echo notfound; fi',
                    gitPath, gitPath)
            end
            local gitTypeOutput = getCommandOutputInDir(tempDir, checkGitTypeCmd) -- Run in tempDir context

            -- Ensure we found a standard directory .git repo root
            if gitTypeOutput and gitTypeOutput:match("directory") then
                repoDir = tempDir
                break
            end
            -- If .git is a file, it might be a submodule or worktree - repo root is likely higher. Keep searching.
        end
        local parentDir = extractFolder(tempDir)
        -- Stop if we reached root or cannot go further up
        if not parentDir or parentDir == tempDir then
            break
        end
        tempDir = parentDir
    end

    if not repoDir then
        app.alert("Could not find a standard Git repository (.git directory) containing this file.")
        app.alert("Was the repository initialized correctly? (e.g., using 'Initialize Git for This File')")
        return
    end

    -- 3. Get Relative Path
    local relativePath = getRelativePath(repoDir, currentFilePath)
    -- If getRelativePath fails, try a simpler extraction if file is directly in repo root
    if not relativePath then
        if repoDir:gsub("\\", "/") == currentDir:gsub("\\", "/") then
            relativePath = currentFileName
        else
            app.alert("Error: Could not determine the file's relative path within the Git repository.")
            app.alert("Repo found at: " .. repoDir)
            app.alert("File path: " .. currentFilePath)
            return
        end
    end

    -- 4. Check for Unsaved Changes in Aseprite
    if sprite.isModified then -- 수정: is_modified -> isModified
        local saveConfirmation = app.alert {
            title = "Unsaved Changes",
            text = "The current file has unsaved changes. Save them before committing?",
            buttons = {"Save and Continue", "Cancel Commit"}
        }
        if saveConfirmation == 1 then
            app.command.SaveFile()
            -- Check again if save was successful
            if sprite.isModified then -- 수정: is_modified -> isModified
                app.alert("Error: Failed to save changes.")
                app.alert("Please save manually and try committing again.")
                return
            end
        else
            app.alert("Commit cancelled.")
            return
        end
    end

    -- 5. Check Git Status for Changes to this specific file
    -- Use quotes around relativePath for safety
    local gitStatusCmd = string.format('git status --porcelain -- "%s"', relativePath:gsub('"', '\\"'))
    local statusOutput, statusErr = getCommandOutputInDir(repoDir, gitStatusCmd)

    if statusOutput == nil then
        app.alert("Failed to get Git status for the file.")
        app.alert("Error: " .. (statusErr or "Unknown error checking Git status"))
        app.alert("Repo: " .. repoDir .. " Cmd: " .. gitStatusCmd) -- Debugging info
        return
    end

    -- Trim whitespace from statusOutput for accurate comparison
    statusOutput = statusOutput:match("^%s*(.-)%s*$")

    if statusOutput == "" then
        app.alert("No changes detected for '" .. currentFileName .. "' compared to the last commit.")
        return
    end

    -- Stage the specific file before showing commit dialog
    local addCmd = string.format('git add -- "%s"', relativePath:gsub('"', '\\"'))
    if not runCommandInDir(repoDir, addCmd, "Git Add File (Staging)") then
        app.alert("Failed to stage changes for the file: " .. relativePath)
        app.alert("Commit aborted.")
        return
    end

    -- 6. Get Commit Message (Using Aseprite Dialog)
    local dlg = Dialog("Git Commit: " .. currentFileName)
    dlg:label{
        text = "Enter commit message:"
    }
    dlg:entry{
        id = "message",
        text = "Update " .. currentFileName,
        expand = true
    }
    dlg:separator{}
    dlg:button{
        id = "ok",
        text = "Commit"
    };
    dlg:button{
        id = "cancel",
        text = "Cancel"
    }
    dlg:show()

    -- 7. Perform Commit
    local data = dlg.data
    if data.ok and data.message and data.message:match("%S") then -- Check if message is not empty/whitespace
        local message = data.message:gsub('"', '\\"') -- Escape double quotes in message
        -- Commit only the staged changes (which should just be our file)
        -- No need to specify file path again in commit if already staged.
        local commitCmd = string.format('git commit -m "%s"', message)

        if runCommandInDir(repoDir, commitCmd, "Git Commit") then
            app.alert("Commit successful for '" .. currentFileName .. "'!")
        else
            -- Commit failed, provide more context
            app.alert("Commit failed for '" .. currentFileName .. "'.")
            app.alert(
                "This might happen if there were no staged changes (e.g., add failed silently) or other Git issues.")
            app.alert("Check console output for detailed Git messages.")
        end
    elseif data.ok then
        app.alert("Commit cancelled: Message cannot be empty.")
        -- Consider unstaging the file if commit is cancelled after staging?
        -- local unstageCmd = string.format('git reset HEAD -- "%s"', relativePath:gsub('"', '\\"'))
        -- runCommandInDir(repoDir, unstageCmd, "Unstage file", true) -- Suppress errors if unstage fails
    else
        app.alert("Commit cancelled.")
        -- Consider unstaging the file if commit is cancelled after staging?
        -- local unstageCmd = string.format('git reset HEAD -- "%s"', relativePath:gsub('"', '\\"'))
        -- runCommandInDir(repoDir, unstageCmd, "Unstage file", true) -- Suppress errors if unstage fails
    end
end

-- ========================================================================
-- == Command: Show Git Log and Preview ==
-- ========================================================================
local function showGitLogAndPreview()
    -- 1. Get Active Sprite and File Path
    local sprite = app.sprite
    if not sprite then
        app.alert("No active file is open.");
        return
    end
    local currentFilePath = sprite.filename
    if not currentFilePath or currentFilePath == "" then
        app.alert("The active file must be saved first.");
        return
    end
    local currentFileName = currentFilePath:match("([^/\\]+)$")
    if not currentFileName then
        app.alert("Error: Could not extract filename.");
        return
    end
    local currentFileExt = currentFileName:match("%.([^.]+)$") or "aseprite" -- 확장자 추출, 없으면 기본값

    local currentDir = extractFolder(currentFilePath)
    if not currentDir then
        app.alert("Error: Could not determine the directory of the current file.");
        return
    end

    -- 2. Find Git Repository Root (gitCommitCurrentFile 로직 재사용)
    local repoDir = nil
    local tempDir = currentDir
    while tempDir do
        if folderIsValidGitRepo(tempDir) then
            local gitPath = tempDir:gsub("\\", "/") .. "/.git"
            local checkGitTypeCmd
            if package.config:sub(1, 1) == "\\" then
                checkGitTypeCmd = string.format(
                    'if exist "%s\\" (echo directory) else (if exist "%s" (echo file) else (echo notfound))',
                    gitPath:gsub("/", "\\"), gitPath:gsub("/", "\\"))
            else
                checkGitTypeCmd = string.format(
                    'if [ -d "%s" ]; then echo directory; elif [ -f "%s" ]; then echo file; else echo notfound; fi',
                    gitPath, gitPath)
            end
            -- Use a function that captures output, like getCommandOutputInDir
            local output, err = getCommandOutputInDir(tempDir, checkGitTypeCmd) -- Use tempDir as context
            if output and output:match("directory") then
                repoDir = tempDir
                break
            end
        end
        local parentDir = extractFolder(tempDir)
        if not parentDir or parentDir == tempDir then
            break
        end
        tempDir = parentDir
    end

    if not repoDir then
        app.alert("Could not find a standard Git repository (.git directory) containing this file.")
        return
    end

    -- 3. Get Relative Path (gitCommitCurrentFile 로직 재사용)
    local relativePath = getRelativePath(repoDir, currentFilePath)
    if not relativePath then
        if repoDir:gsub("\\", "/") == currentDir:gsub("\\", "/") then
            relativePath = currentFileName
        else
            app.alert("Error: Could not determine the file's relative path within the Git repository.")
            return
        end
    end

    -- 4. Execute git log for the specific file
    -- Format: Hash<TAB>AuthorName<TAB>ShortDate<TAB>Subject
    -- Using %x09 for TAB as delimiter
    local logFormat = "%H%x09%an%x09%ad%x09%s"
    -- Limit to 50 entries for performance, track file (if git supports --follow well)
    local logCmd = string.format('git log -n 50 --pretty=format:"%s" --date=short -- "%s"', logFormat,
        relativePath:gsub('"', '\\"'))
    local logOutput, logErr = getCommandOutputInDir(repoDir, logCmd)

    if not logOutput or logOutput == "" then
        app.alert("Could not retrieve Git log for this file.\n" .. (logErr or "No history found or Git error."))
        return
    end

    -- 5. Parse Log Output
    local commits = {}
    local listItems = {}
    -- Split by newline, then by tab
    for line in logOutput:gmatch("[^\r\n]+") do
        local parts = {}
        for part in line:gmatch("[^\t]+") do
            table.insert(parts, part)
        end
        if #parts >= 4 then -- Expecting Hash, Author, Date, Subject
            local commitData = {
                hash = parts[1],
                author = parts[2],
                date = parts[3],
                subject = parts[4]
            }
            table.insert(commits, commitData)
            -- Format for listbox: "Date - Subject (Author)"
            table.insert(listItems,
                string.format("%s - %s (%s)", commitData.date, commitData.subject, commitData.author))
        else
            print("Warning: Skipping malformed log line: " .. line)
        end
    end

    if #commits == 0 then
        app.alert("No parsable commit history found for this file.")
        return
    end

    -- 6. Show Dialog with Log
    local dlg = Dialog("Git Log: " .. currentFileName)
    dlg:label{
        text = "Select a commit to view:"
    } -- 레이블 텍스트 약간 수정
    dlg:combobox{
        id = "commitlist",
        options = listItems
    }
    dlg:separator{}
    dlg:button{
        id = "preview",
        text = "Open Tempview Selected" -- !!!!! 수정: 버튼 텍스트 변경 !!!!!
    }
    dlg:button{
        id = "cancel",
        text = "Cancel"
    }
    dlg:show()

    -- 7. Handle Dialog Result
    local data = dlg.data

    -- Preview 버튼을 눌렀고, commitlist에 값이 있는지 확인 (이제 문자열 값임)
    if data.preview and data.commitlist then

        local selectedText = data.commitlist -- combobox에서 반환된 선택된 텍스트
        local selectedIndex = nil

        -- listItems 테이블을 순회하며 선택된 텍스트(selectedText)와 일치하는 항목의 인덱스(i)를 찾음
        for i, itemText in ipairs(listItems) do
            if itemText == selectedText then
                selectedIndex = i -- 인덱스를 찾으면 저장하고 반복 종료
                break
            end
        end

        -- 유효한 인덱스를 찾았는지 확인
        if selectedIndex then
            -- 찾은 인덱스(selectedIndex)를 사용하여 commits 테이블에서 해당 커밋 정보를 가져옴
            local selectedCommit = commits[selectedIndex]

            if not selectedCommit then
                -- 이론적으로는 selectedIndex를 찾았다면 여기로 오면 안 되지만, 안전을 위해 확인
                app.alert("Error: Could not find commit data for the selection.")
                return
            end

            -- ==============================================================
            -- !!!!! 여기서부터 기존의 미리보기 로직 (8번 단계 이후) 시작 !!!!!
            -- selectedCommit.hash 등을 사용하여 임시 파일 생성 및 열기
            -- ==============================================================

            -- 8. Get file content at the selected commit and save to temp file
            -- getTemporaryFilePath 함수가 이제 "TEMP_" 접두사가 붙은 경로를 반환함
            local tempFilePath = getTemporaryFilePath(currentFileName, selectedCommit.hash, currentFileExt)
            if not tempFilePath then
                app.alert("Error: Could not generate a temporary file path.")
                return
            end

            -- Use redirection (>) for safer binary file handling
            local showCmd = string.format('git show "%s:%s"', selectedCommit.hash, relativePath:gsub('"', '\\"')) -- Path inside repo
            local redirectCmd
            local tempFilePathShell = tempFilePath:gsub('"', '\\"') -- Escape quotes for shell
            local success -- Declare success variable outside the if/else block

            if package.config:sub(1, 1) == "\\" then
                -- Windows
                local cmdFilePath = os.tmpname() .. ".cmd"
                local cmdFile = io.open(cmdFilePath, "w")
                if not cmdFile then
                    app.alert("Failed to create temporary command file.");
                    return
                end
                cmdFile:write(string.format('@echo off\ncd /d "%s"\n%s > "%s"\n', repoDir:gsub("/", "\\"), showCmd,
                    tempFilePathShell))
                cmdFile:close()
                local result = os.execute(string.format('cmd /c "%s"', cmdFilePath))
                success = (result == true or result == 0)
                pcall(os.remove, cmdFilePath) -- Use pcall for safer remove
                if not success then
                    app.alert("Failed to retrieve file content from Git history (git show failed). Check console.")
                    return
                end
            else
                -- POSIX
                redirectCmd = string.format('cd "%s" && %s > "%s"', repoDir, showCmd, tempFilePathShell)
                local result = os.execute(redirectCmd)
                success = (result == true or result == 0)
                if not success then
                    app.alert("Failed to retrieve file content from Git history (git show failed). Check console.")
                    return
                end
            end

            -- Check if the temp file was actually created and has content
            local f = io.open(tempFilePath, "rb")
            if not f then
                app.alert("Error: Failed to save historical version to temporary file: " .. tempFilePath)
                return
            end
            local size = f:seek("end")
            f:close()

            if not size or size == 0 then -- Check for nil size as well
                app.alert("Error: Git retrieved an empty file for this commit, or failed to get file size.")
                pcall(os.remove, tempFilePath) -- Clean up empty/problematic file
                return
            end

            -- 9. Open the temporary file in Aseprite
            app.open(tempFilePath) -- 파일 이름에 "TEMP_"가 포함되어 열림
            app.alert("Opened temporary view for commit: " .. selectedCommit.hash:sub(1, 7))
        else
            -- 선택된 텍스트가 listItems에 없는 경우 (이론상 발생하기 어려움)
            app.alert("Error: Could not match selected item text to commit list.")
            print("Error: Failed to find index for selected text:", selectedText)
        end

    elseif data.cancel then
        -- User cancelled
        -- app.alert("Operation cancelled.")
    else
        -- Preview 버튼 안 눌렀거나, data.commitlist가 nil/false인 경우 (예: 아무것도 선택 안함)
        if data.preview then
            app.alert("Please select a commit from the list before clicking 'Open Tempview Selected'.") -- 버튼 이름 반영
        end
    end
end

-- ======================================================
-- == Register Commands ==
-- ======================================================
function init(plugin)
    local scriptGroup = "file_scripts" -- Or choose a more descriptive group name

    plugin:newCommand{
        id = "MoveAndInitGitForFile",
        title = "Initialize Git for Focused File", -- Creates subfolder, moves file, inits repo
        group = scriptGroup,
        onclick = initializeGitForCurrentFile
    }

    plugin:newCommand{
        id = "GitCommitCurrentFile",
        title = "Git Commit Focused File", -- Commits the currently open file in its repo
        group = scriptGroup,
        onclick = gitCommitCurrentFile
    }

    plugin:newCommand{
        id = "GitShowLogAndPreview",
        title = "Git Log & Temp View File", -- !!!!! 수정: 메뉴 이름도 약간 수정 !!!!!
        group = scriptGroup,
        onclick = showGitLogAndPreview
    }
end

-- String.startswith polyfill if not available
if not string.startswith then
    function string.startswith(self, start)
        return self:sub(1, #start) == start
    end
end
