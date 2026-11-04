import SwiftUI

// Name the stable property-wrapper type explicitly on SDKs that also export a State macro.
typealias LocalState<Value> = SwiftUI.State<Value>
