-- Chooses one item of the Simulator app's menus. With two names: a menu and its
-- item, as in "Device" "Rotate Left". With three: a menu, an item with a submenu,
-- and the item of that submenu.
on run argv
	tell application "System Events"
		tell process "Simulator"
			set frontmost to true
			if (count of argv) is 2 then
				click menu item (item 2 of argv) of menu 1 of menu bar item (item 1 of argv) of menu bar 1
			else
				click menu item (item 3 of argv) of menu 1 of menu item (item 2 of argv) of menu 1 of menu bar item (item 1 of argv) of menu bar 1
			end if
		end tell
	end tell
	return "clicked"
end run
