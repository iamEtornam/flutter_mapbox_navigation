import MapboxMaps
import MapboxNavigationCore
import MapboxNavigationUIKit

class CustomDayStyle: DayStyle {

    private static let defaultDayStyleURL = "mapbox://styles/mapbox/navigation-day-v1"

    required init() {
        super.init()
        initStyle()
    }

    init(url: String?){
        super.init()
        initStyle()
        if(url != nil)
        {
            mapStyleURL = URL(string: url!) ?? URL(string: CustomDayStyle.defaultDayStyleURL)!
        }
    }

    func initStyle()
    {
        // Use a custom map style.
        mapStyleURL = URL(string: CustomDayStyle.defaultDayStyleURL)!

        // Specify that the style should be used during the day.
        styleType = .day
    }

    override func apply() {
        super.apply()
        // Begin styling the UI
    }
}
