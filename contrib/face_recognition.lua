--[[
  Face recognition for darktable

  Copyright (c) 2017  Sebastian Witt
   
  darktable is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  darktable is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with darktable.  If not, see <http://www.gnu.org/licenses/>.
]]

--[[
face_recognition
Add a new storage option to send images to face_recognition.
Images are exported to darktable tmp dir first.
A directory with known faces must exist, the image name are the
tag names which will be used.
Multiple images for one face can exist, add a number to it, the
number will be removed from the tag, for example:
People|IknowYou1.jpg
People|IknowYou2.jpg
People|Another.jpg
People|Youtoo.jpg

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
* https://github.com/ageitgey/face_recognition
* https://github.com/darktable-org/lua-scripts/tree/master/lib

USAGE
* require this file from your main luarc config file.

This plugin will add a new storage option and calls face_recognition after export.
]]

local dt = require "darktable"
local df = require "lib/dtutils.file"
local gettext = dt.gettext

-- works with darktable API version from 2.0.0 to 5.0.0
dt.configuration.check_version(...,{2,0,0},{3,0,0},{4,0,0},{5,0,0})

-- Tell gettext where to find the .mo file translating messages for a particular domain
gettext.bindtextdomain("face_recognition", dt.configuration.config_dir.."/lua/locale/")

local function _(msgid)
    return gettext.dgettext("face_recognition", msgid)
end

-- Preference: Tag for unknown_person
dt.preferences.register("FaceRecognition",
                        "unknownTag",
                        "string",                                                               -- type
                        _("Face recognition: Unknown tag"),                                     -- label
                        _("Tag for faces that are not recognized"),                             -- tooltip
                        "unknown_person")
-- Preference: Images with this substring in tags are ignored
dt.preferences.register("FaceRecognition",
                        "ignoreTags",
                        "string",                                                               -- type
                        _("Face recognition: Ignore tag"),                                      -- label
                        _("Images with this substring in tags are ignored, separate multiple strings with ,"),   -- tooltip
                        "")
-- Preference: Number of CPU cores to use
dt.preferences.register("FaceRecognition",
                        "nrCores",
                        "integer",                                                              -- type
                        _("Face recognition: Nr of CPU cores"),                                 -- label
                        _("Number of CPU cores to use, 0 for all"),                             -- tooltip
                        0,                                                                      -- default
                        0,                                                                      -- min
                        64)                                                                     -- max
-- Preference: Known faces path
dt.preferences.register("FaceRecognition",
                        "knownImagePath",
                        "directory",                                                            -- type
                        _("Face recognition: Known images"),                                    -- label
                        _("Path to images with known faces, files named after tag to apply"),   -- tooltip
                        "~/.config/darktable/face_recognition")                                 -- default                                                                  -- default
                        
local function show_status (storage, image, format, filename, number, total, high_quality, extra_data)
  dt.print("Export to Face recognition "..tostring(number).."/"..tostring(total))
end

-- Check if image has ignored tag attached
local function ignoreByTag (image, ignoreTags)
  local tags = image:get_tags ()
  local ignoreImage = false
  -- For each image tag
  for _,t in ipairs (tags) do
    -- Check if it contains a ignore tag
    for _,it in ipairs (ignoreTags) do
      if string.find (t.name, it, 1, true) then
        -- The image has ignored tag attached
        ignoreImage = true
        dt.print_error ("Face recognition: Ignored tag: " .. it .. " found in " .. image.id .. ":" .. t.name)
      end
    end
  end
  
  return ignoreImage
end

local function face_recognition (storage, image_table, extra_data) --finalize
  if not df.check_if_bin_exists("face_recognition") then
    dt.print(_("Face recognition not found"))
    return
  end

  -- Get preferences
  local knownPath = dt.preferences.read("FaceRecognition", "knownImagePath", "directory")
  local nrCores = dt.preferences.read("FaceRecognition", "nrCores", "integer")
  local ignoreTagString = dt.preferences.read("FaceRecognition", "ignoreTags", "string")
  local unknownTag = dt.preferences.read("FaceRecognition", "unknownTag", "string")

  -- face_recognition uses -1 for all cores, we use 0 in preferences
  if nrCores < 1 then
    nrCores = -1
  end
  
  -- Split ignore tags (if any)
  ignoreTags = {}
  for tag in string.gmatch(ignoreTagString, '([^,]+)') do
    table.insert (ignoreTags, tag)
    dt.print_error ("Face recognition: Ignore tag: " .. tag)
  end
  
  -- list of exported images
  local img_list = {}

  for img,v in pairs(image_table) do
    table.insert (img_list, v)
  end

  -- Get path of exported images
  local path = df.get_path (img_list[1])
  dt.print_error ("Face recognition: Path to unknown images: " .. path)

  -- Output file
  local output = path .. "facerecognition.txt"
  
  local command = "face_recognition --cpus " .. nrCores .. " " .. knownPath .. " " .. path .. " > " .. output
  dt.print_error("Face recognition: Running command: " .. command)
  dt.print(_("Starting face recognition..."))

  dt.control.execute(command)

  -- Remove exported images
  for _,v in ipairs(img_list) do
    os.remove (v)
  end
  
  -- Open output file
  local f = io.open(output, "rb")
  
  if not f then
    dt.print(_("Face recognition failed"))
  else
    dt.print(_("Face recognition finished"))
    f:close ()
  end
  
  -- Read output
  local result = {}
  for line in io.lines(output) do 
    local file, tag = string.match (line, "(.*),(.*)$")
    tag = string.gsub (tag, "%d*$", "")
    dt.print_error ("File:"..file .." Tag:".. tag)
    if result[file] ~= nil then
      table.insert (result[file], tag)
    else
      result[file] = {tag}
    end
  end
  
  -- Attach tags
  for file,tags in pairs(result) do
    -- Find image in table
    for img,file2 in pairs(image_table) do
      if file == file2 then
        for _,t in ipairs (tags) do
          -- Check if image is ignored
          if ignoreByTag (img, ignoreTags) then
            dt.print_error("Face recognition: Ignoring image with ID " .. img.id)
          else
            -- Check of unrecognized unknown_person
            if t == "unknown_person" then
              t = unknownTag
            end
            dt.print_error ("ImgId:" .. img.id .. " Tag:".. t)
            -- Create tag if it does not exists
            local tag = dt.tags.create (t)
            img:attach_tag (tag)
          end
        end
      end
    end
  end
  
  --os.remove (output) 

end

-- Register
dt.register_storage("module_face_recognition", _("Face recognition"), show_status, face_recognition)

--
-- vim: shiftwidth=2 expandtab tabstop=2 cindent syntax=lua
