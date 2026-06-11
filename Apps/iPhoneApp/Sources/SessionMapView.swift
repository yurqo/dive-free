import SwiftUI
import MapKit
import Domain

/// A MapKit view centred on where a session took place, with a custom dive-site
/// pin. Use `interactive: false` for the small list thumbnail and the default
/// for the full map on the detail screen.
struct SessionMapView: View {
    let location: GeoPoint
    var interactive: Bool = true

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: interactive ? .all : []) {
            Annotation("Dive site", coordinate: coordinate) {
                ZStack {
                    Circle()
                        .fill(.teal)
                        .frame(width: 28, height: 28)
                        .shadow(radius: 1)
                    Image(systemName: "figure.open.water.swim")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .annotationTitles(interactive ? .automatic : .hidden)
        }
    }
}
