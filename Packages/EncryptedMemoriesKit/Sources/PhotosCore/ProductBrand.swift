import Foundation

public enum ProductBrand {
    public static var displayName: String {
        L10n.string("brand.product_name")
    }

    /// The quiet origin line shown in the About area of Settings on every platform.
    public static var madeInAustria: String {
        L10n.string("brand.made_in_austria")
    }
}
