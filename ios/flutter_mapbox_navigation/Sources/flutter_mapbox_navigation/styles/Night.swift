import MapboxMaps
import MapboxNavigationCore
import MapboxNavigationUIKit

class CustomNightStyle: NightStyle {

    private static let defaultNightStyleURL = "mapbox://styles/mapbox/navigation-night-v1"

    required init() {
        super.init()
        initStyle()
    }

    init(url: String?){
        super.init()
        initStyle()
        if(url != nil)
        {
            mapStyleURL = URL(string: url!) ?? URL(string: CustomNightStyle.defaultNightStyleURL)!
        }
    }

    func initStyle()
    {
        // Use a custom map style.
        mapStyleURL = URL(string: CustomNightStyle.defaultNightStyleURL)!

        // Specify that the style should be used at night.
        styleType = .night
    }

    override func apply() {
        super.apply()
        // Begin styling the UI
    }
}
