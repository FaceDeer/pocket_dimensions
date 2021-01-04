A pocket dimension is an independent section of space-time that can only be accessed through a restricted pathway, but which is still nevertheless a part of the same universe you're accessing it from. It is quite small compared to the rest of the universe, a restricted "bubble" with impenetrable boundaries, but still large enough on a human scale to serve any number of purposes.

Pocket dimensions can be a redoubt to retreat to for protection, a repository to securely store valuables, a private garden in which to find solitude or to practice crafts in peace, or even as a social hub where multiple visitors can congregate.

When a being enters a pocket dimension they carry with them a thin strand of spacetime that connects them back to the point in the outside universe they departed from. When leaving a pocket dimension - which can be accomplished simply by closely approaching the boundary of the pocket and right-clicking it - the traveler will automatically snap back to that location again.

# Configurable Pocket Types

This mod provides a variety of settings that allow server admins to enable or disable different types of pocket dimensions and how they may be created or accessed.

* Automatic personal pockets - each player can automatically access one protected pocket dimension that they own.
* "portals" that allow access to existing public pocket dimensions, possibly set up ahead of time by the server admin

# Settings

* ``pocket_dimensions_altitude`` - the y-coordinate "layer" at which pocket dimensions will be physically present in the world. Defaults to y = 30000. Try to ensure that this doesn't overlap with any regions that the players will normally be able to reach, this mod may overwrite chunks of map at this altitude in the course of gameplay. Don't change this value once pocket dimensions have been created or all previously created pocket dimensions will be inaccessible.

* ``pocket_dimensions_personal_pockets`` - enables the /pocket_personal chat command that lets players create and teleport to a single personal pocket dimension