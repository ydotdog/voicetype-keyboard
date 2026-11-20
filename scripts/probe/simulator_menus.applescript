-- Lists the Simulator app's menus, one item per line: its path through the menus,
-- whether it can be chosen, and its check mark. The fields are separated by tabs.
on run
	set menuReport to ""
	tell application "System Events"
		tell process "Simulator"
			repeat with barItem in menu bar items of menu bar 1
				set barTitle to my titleOf(name of barItem)
				try
					repeat with menuEntry in menu items of menu 1 of barItem
						set entryTitle to my titleOf(name of menuEntry)
						if entryTitle is not "" then
							set menuReport to menuReport & barTitle & " > " & entryTitle & tab & my flagsOf(menuEntry) & linefeed
							try
								repeat with childEntry in menu items of menu 1 of menuEntry
									set childTitle to my titleOf(name of childEntry)
									if childTitle is not "" then
										set menuReport to menuReport & barTitle & " > " & entryTitle & " > " & childTitle & tab & my flagsOf(childEntry) & linefeed
									end if
								end repeat
							end try
						end if
					end repeat
				end try
			end repeat
		end tell
	end tell
	return menuReport
end run

on titleOf(givenName)
	if givenName is missing value then return ""
	return givenName as text
end titleOf

on flagsOf(menuEntry)
	set enabledText to "disabled"
	set markText to ""
	tell application "System Events"
		try
			if enabled of menuEntry then set enabledText to "enabled"
		end try
		try
			set markValue to value of attribute "AXMenuItemMarkChar" of menuEntry
			if markValue is not missing value then set markText to markValue as text
		end try
	end tell
	return enabledText & tab & markText
end flagsOf
