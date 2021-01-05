A pocket dimension is an independent section of space-time that can only be accessed through a restricted pathway, but which is still nevertheless a part of the same universe you're accessing it from. It is quite small compared to the rest of the universe, a restricted "bubble" with impenetrable boundaries, but still large enough on a human scale to serve any number of purposes.

Pocket dimensions can be a redoubt to retreat to for protection, a repository to securely store valuables, a private garden in which to find solitude or to practice crafts in peace, or even as a social hub where multiple visitors can congregate.

When a being enters a pocket dimension they carry with them a thin strand of spacetime that connects them back to the point in the outside universe they departed from. When leaving a pocket dimension - which can be accomplished simply by closely approaching the boundary of the pocket and punching it - the traveler will automatically snap back to that location again.

This mod provides a variety of settings that allow server admins to enable or disable different types of pocket dimensions and how they may be created or accessed.

* Automatic personal pockets - each player can automatically create and access one protected pocket dimension that they own.
* "Portal" nodes that allow access to existing public pocket dimensions set up ahead of time by the server admin

This mod is compatible with both the default minetest game and Mineclone2, and will function serviceably even without either of those two.

# Settings

* ``pocket_dimensions_altitude`` - the y-coordinate "layer" at which pocket dimensions will be physically present in the world. Defaults to y = 30000. Try to ensure that this doesn't overlap with any regions that the players will normally be able to reach, this mod may overwrite chunks of map at this altitude in the course of gameplay.

* ``pocket_dimensions_personal_pockets`` - enables the /pocket_personal chat command that lets players create and teleport to a single personal pocket dimension

# Commands

* ``/pocket_admin`` is available to server admins and opens up a formspec that allows pocket dimensions to be managed. Pocket dimensions can be created or deleted here (and undeleted), they can have their ownership set, and they can be protected or unprotected.

* ``/pocket_personal`` teleports you directly to your personal pocket dimension, if this feature has been enabled on this server. If this is your first time visiting your pocket dimension you'll need to provide a name for it as a parameter.

* ``/pocket_entry`` resets the "arrival" point of the pocket dimension you're currently inside to your current location. This command is only available if you're a server admin or if you're inside a pocket dimension that you're the owner of.

* ``/pocket_rename`` similarly allows you to change the name of the pocket dimension you're inside, subject to the same conditions.

* ``/pocket_name`` tells you the name of the pocket dimension you're currently inside.

# License

This mod is released under the MIT license. voxelarea_iterator.lua is separately licensed under the LGPL, as it is derived from Minetest code; see that file's header for more details. Media may be under different licenses, see license.txt in the corresponding folders for details.