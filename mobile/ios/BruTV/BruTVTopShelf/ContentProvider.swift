import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> TVTopShelfContent? {
        let store = TopShelfStore.shared
        let payload = store.loadPayload()

        var collections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        // Continue Watching Shelf
        if !payload.continueWatching.isEmpty {
            let continueItems = payload.continueWatching.map { item -> TVTopShelfSectionedItem in
                let shelfItem = TVTopShelfSectionedItem(identifier: "continue-\(item.id)")
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    shelfItem.title = "\(item.title) · \(subtitle)"
                } else {
                    shelfItem.title = item.title
                }
                shelfItem.imageShape = item.kind == "live" ? .square : .poster
                if let imageURL = item.imageURL {
                    shelfItem.setImageURL(imageURL, for: .screenScale1x)
                    shelfItem.setImageURL(imageURL, for: .screenScale2x)
                }
                if let playURL = item.playURL {
                    shelfItem.playAction = TVTopShelfAction(url: playURL)
                }
                if let displayURL = item.displayURL {
                    shelfItem.displayAction = TVTopShelfAction(url: displayURL)
                }
                return shelfItem
            }
            let collection = TVTopShelfItemCollection(items: continueItems)
            collection.title = "Continue Watching"
            collections.append(collection)
        }

        // Favorites Shelf
        if !payload.favorites.isEmpty {
            let favoriteItems = payload.favorites.map { item -> TVTopShelfSectionedItem in
                let shelfItem = TVTopShelfSectionedItem(identifier: "fav-\(item.id)")
                shelfItem.title = item.title
                shelfItem.imageShape = .square
                if let imageURL = item.imageURL {
                    shelfItem.setImageURL(imageURL, for: .screenScale1x)
                    shelfItem.setImageURL(imageURL, for: .screenScale2x)
                }
                if let playURL = item.playURL {
                    shelfItem.playAction = TVTopShelfAction(url: playURL)
                }
                if let displayURL = item.displayURL {
                    shelfItem.displayAction = TVTopShelfAction(url: displayURL)
                }
                return shelfItem
            }
            let collection = TVTopShelfItemCollection(items: favoriteItems)
            collection.title = "Favorite Channels"
            collections.append(collection)
        }

        guard !collections.isEmpty else {
            return nil
        }

        return TVTopShelfSectionedContent(sections: collections)
    }
}
