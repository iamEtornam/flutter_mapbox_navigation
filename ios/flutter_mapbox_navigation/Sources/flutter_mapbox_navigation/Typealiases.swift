import MapboxDirections

// `MapboxNavigationCore` re-exports several `MapboxDirections` types via typealiases
// (Waypoint, ProfileIdentifier, RouteLeg, RouteStep, …). Because this plugin imports
// both modules, those bare names are otherwise ambiguous. Declaring them here — in our
// own module — shadows the imported declarations so the bare names resolve everywhere.
public typealias Waypoint = MapboxDirections.Waypoint
public typealias ProfileIdentifier = MapboxDirections.ProfileIdentifier
public typealias RouteLeg = MapboxDirections.RouteLeg
public typealias RouteStep = MapboxDirections.RouteStep
