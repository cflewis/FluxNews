import 'package:flutter/material.dart';
import 'package:flutter_logs/flutter_logs.dart';
import 'package:flux_news/flux_news_counter_state.dart';
import 'package:flux_news/logging.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_gen/gen_l10n/flux_news_localizations.dart';

import 'flux_news_state.dart';
import 'miniflux_backend.dart';
import 'news_model.dart';

// function to insert news in database which are located in the newsList parameter
Future<int> insertNewsInDB(NewsList newsList, FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('insertNewsInDB', 'Starting inserting news in DB', LogLevel.INFO);
  }
  // init the return value of the function
  int result = 0;
  // if not already initialized, init the database
  appState.db ??= await appState.initializeDB();
  // init result to check the existence of the news
  List<Map<String, Object?>> resultSelect = [];
  // prevent a uninitialized database
  if (appState.db != null) {
    // iterate over the new news
    for (News news in newsList.news) {
      if (!appState.longSyncAborted) {
        // check if news already present in the database
        resultSelect = await appState.db!
            .rawQuery('SELECT * FROM news WHERE newsID = ?', [news.newsID]);
        // if the news is not present, insert the news
        if (resultSelect.isEmpty) {
          result = await appState.db!.insert('news', news.toMap());

          // insert the first image attachment of the news in the attachments db
          Attachment imageAttachment = news.getFirstImageAttachment();
          if (imageAttachment.attachmentID != -1) {
            resultSelect = await appState.db!
                .rawQuery('SELECT * FROM attachments WHERE attachmentID = ?',
                [imageAttachment.attachmentID]);
            // if the attachment is not present, insert the attachment
            if (resultSelect.isEmpty) {
              result =
              await appState.db!.insert('attachments', imageAttachment.toMap());
            }
          }

          if (appState.debugMode) {
            logThis('insertNewsInDB',
                'Inserted news with id ${news.newsID} in DB', LogLevel.INFO);
          }
        } else {
          // if the news is present, update the status of the news
          result = await appState.db!.rawUpdate(
              'UPDATE news SET status = ?, syncStatus = ? WHERE newsId = ?',
              [news.status, FluxNewsState.notSyncedSyncStatus, news.newsID]);
          if (appState.debugMode) {
            logThis(
                'insertNewsInDB', 'Updated news with id ${news.newsID} in DB',
                LogLevel.INFO);
          }
        }
        // check if the feed of the news already contains an icon
        resultSelect = await appState.db!
            .rawQuery('SELECT icon FROM feeds WHERE feedID = ?', [news.feedID]);
        if (resultSelect.isEmpty) {
          // if the feed doesn't contain a icon, fetch the icon from the miniflux server
          FeedIcon? icon =
          await getFeedIcon(http.Client(), appState, news.feedID);
          if (icon != null) {
            // if the icon is successfully fetched, insert the icon into the database
            result = await appState.db!.rawInsert(
                'INSERT INTO feeds (feedID, title, icon, iconMimeType) VALUES(?,?,?,?)',
                [
                  news.feedID,
                  news.feedTitle,
                  icon.getIcon(),
                  icon.iconMimeType
                ]);
            if (appState.debugMode) {
              logThis(
                  'insertNewsInDB',
                  'Inserted Feed icon for feed with id ${news.feedID} in DB',
                  LogLevel.INFO);
            }
          }
        }
      } else {
        if (appState.debugMode) {
          logThis('insertNewsInDB', 'Aborted inserting news in DB',
              LogLevel.INFO);
        }
        break;
      }
    }
  }
  if (appState.debugMode) {
    logThis('insertNewsInDB', 'Finished inserting news in DB', LogLevel.INFO);
  }
  // return the result from the inserts into the database
  return result;
}

// update the bookmarked news in the database which are located in the newsList parameter
Future<int> updateStarredNewsInDB(
    NewsList newsList, FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('updateStarredNewsInDB', 'Starting updating starred news in DB',
        LogLevel.INFO);
  }
  int result = 0;
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    List<Map<String, Object?>> resultSelect = [];
    for (News news in newsList.news) {
      // check if the news is already marked as bookmarked
      resultSelect = await appState.db!.rawQuery(
          'SELECT * FROM news WHERE newsID = ? AND starred = ?',
          [news.newsID, 1]);
      if (resultSelect.isEmpty) {
        // if the news is not already marked, mark it as bookmarked
        result = await appState.db!.rawUpdate(
            'UPDATE news SET starred = ? WHERE newsId = ?', [1, news.newsID]);
        if (appState.debugMode) {
          logThis(
              'updateStarredNewsInDB',
              'Marked news with id ${news.newsID} as bookmarked in DB',
              LogLevel.INFO);
        }
      }
    }
    // check if the existing bookmarks also exist in the given list.
    // if not, delete the bookmark flag at the news
    List<News> existingNotStarredNews = [];
    resultSelect = await appState.db!
        .rawQuery('SELECT * FROM news WHERE starred = ?', [1]);
    if (resultSelect.isNotEmpty) {
      existingNotStarredNews =
          resultSelect.map((e) => News.fromMap(e)).toList();
    }
    for (News news in existingNotStarredNews) {
      if (!newsList.news.any((item) => item.newsID == news.newsID)) {
        result = await appState.db!.rawUpdate(
            'UPDATE news SET starred = ? WHERE newsId = ?', [0, news.newsID]);
        if (appState.debugMode) {
          logThis(
              'updateStarredNewsInDB',
              'Deleted starred status for news with id ${news.newsID} in DB',
              LogLevel.INFO);
        }
      }
    }
  }
  if (appState.debugMode) {
    logThis('updateStarredNewsInDB', 'Finished updating starred news in DB',
        LogLevel.INFO);
  }
  return result;
}

// check if the local unread news exists in the list of new fetched unread news.
// if the news doesn't exists, it means that this news was marked by another app as read.
// so we mark the news also as read.
Future<int> markNotFetchedNewsAsRead(
    NewsList newNewsList, FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('markNotFetchedNewsAsRead',
        'Starting marking not fetched news as read', LogLevel.INFO);
  }
  int result = 0;
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    List<Map<String, Object?>> resultSelect = [];
    List<News> existingNews = [];
    // get the local unread news
    resultSelect = await appState.db!.rawQuery(
        'SELECT * FROM news WHERE status = ? AND syncStatus = ?',
        [FluxNewsState.unreadNewsStatus, FluxNewsState.notSyncedSyncStatus]);
    if (resultSelect.isNotEmpty) {
      existingNews = resultSelect.map((e) => News.fromMap(e)).toList();
    }

    for (News news in existingNews) {
      if (!appState.longSyncAborted) {
        // check if the news exists in the unread news list which was fetched.
        if (!newNewsList.news.any((item) => item.newsID == news.newsID)) {
          // if not, mark the news as read
          result = await appState.db!.rawUpdate(
              'UPDATE news SET status = ?, syncStatus = ? WHERE newsId = ?', [
            FluxNewsState.readNewsStatus,
            FluxNewsState.syncedSyncStatus,
            news.newsID
          ]);
          if (appState.debugMode) {
            logThis(
                'markNotFetchedNewsAsRead',
                'Marked the news with id ${news.newsID} as read in DB',
                LogLevel.INFO);
          }
        }
      } else {
        if (appState.debugMode) {
          logThis('markNotFetchedNewsAsRead', 'Aborted marking not fetched news as read',
              LogLevel.INFO);
        }
        break;
      }
    }
  }
  if (appState.debugMode) {
    logThis('markNotFetchedNewsAsRead',
        'Finished marking not fetched news as read', LogLevel.INFO);
  }
  return result;
}

// get the local saved news from the database
Future<List<News>> queryNewsFromDB(
    FluxNewsState appState, List<int>? feedIDs) async {
  if (appState.debugMode) {
    logThis('queryNewsFromDB', 'Starting querying news from DB', LogLevel.INFO);
  }
  List<News> newList = [];
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    String status = '';
    // decide if the news status is set to display all news or only the unread
    if (appState.newsStatus == FluxNewsState.allNewsString) {
      status = FluxNewsState.databaseAllString;
    } else {
      status = appState.newsStatus;
    }

    // decide if the sort order is ascending or descending
    String sortOrder = FluxNewsState.databaseDescString;
    if (appState.sortOrder != null) {
      if (appState.sortOrder == FluxNewsState.sortOrderNewestFirstString) {
        sortOrder = FluxNewsState.databaseDescString;
      } else {
        sortOrder = FluxNewsState.databaseAscString;
      }
    }

    if (feedIDs != null) {
      // if the feed id is not null a category, a feed or the bookmarked news ar selected
      if (appState.feedIDs?.first == -1) {
        // if the feed id is -1 the bookmarked news are selected
        List<Map<String, Object?>> queryResult =
            await appState.db!.rawQuery('''SELECT news.newsID, 
                      news.feedID, 
                      news.title, 
                      news.url, 
                      news.content, 
                      news.hash, 
                      news.publishedAt, 
                      news.createdAt, 
                      news.status, 
                      news.readingTime, 
                      news.starred, 
                      news.feedTitle, 
                      news.syncStatus,
                      feeds.icon,
                      feeds.iconMimeType,
                      attachments.attachmentURL,
                      attachments.attachmentMimeType
                FROM news 
                LEFT OUTER JOIN feeds ON news.feedID = feeds.feedID
                LEFT OUTER JOIN attachments ON news.newsID = attachments.newsID
                WHERE news.starred = ? 
                ORDER BY news.publishedAt $sortOrder''', [1]);
        newList.addAll(queryResult.map((e) => News.fromMap(e)).toList());
      } else {
        // if the feed id is not -1 a feed or a category with multiple feeds is selected
        for (int feedID in feedIDs) {
          List<Map<String, Object?>> queryResult =
              await appState.db!.rawQuery('''SELECT news.newsID, 
                      news.feedID, 
                      news.title, 
                      news.url, 
                      news.content, 
                      news.hash, 
                      news.publishedAt, 
                      news.createdAt, 
                      news.status, 
                      news.readingTime, 
                      news.starred, 
                      news.feedTitle, 
                      news.syncStatus,
                      feeds.icon,
                      feeds.iconMimeType,
                      attachments.attachmentURL,
                      attachments.attachmentMimeType 
                  FROM news 
                  LEFT OUTER JOIN feeds ON news.feedID = feeds.feedID
                  LEFT OUTER JOIN attachments ON news.newsID = attachments.newsID
                  WHERE (news.status LIKE ?) 
                    AND news.feedID LIKE ? 
                  ORDER BY news.publishedAt $sortOrder''', [status, feedID]);
          newList.addAll(queryResult.map((e) => News.fromMap(e)).toList());
        }
      }
    } else {
      // if the feed id is null, "all news" are selected
      List<Map<String, Object?>> queryResult =
          await appState.db!.rawQuery('''SELECT news.newsID, 
                      news.feedID, 
                      news.title, 
                      news.url, 
                      news.content, 
                      news.hash, 
                      news.publishedAt, 
                      news.createdAt, 
                      news.status, 
                      news.readingTime, 
                      news.starred, 
                      news.feedTitle, 
                      news.syncStatus,
                      feeds.icon,
                      feeds.iconMimeType,
                      attachments.attachmentURL,
                      attachments.attachmentMimeType
              FROM news 
              LEFT OUTER JOIN feeds ON news.feedID = feeds.feedID
              LEFT OUTER JOIN attachments ON news.newsID = attachments.newsID
              WHERE (news.status LIKE ?) 
              ORDER BY news.publishedAt $sortOrder''', [status]);
      newList.addAll(queryResult.map((e) => News.fromMap(e)).toList());
    }
  }
  if (appState.debugMode) {
    logThis('queryNewsFromDB', 'Finished querying news from DB', LogLevel.INFO);
  }
  return newList;
}

// update the status (read or unread) of the news in the database
void updateNewsStatusInDB(
    int newsID, String status, FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('updateNewsStatusInDB', 'Starting updating news status in DB',
        LogLevel.INFO);
  }
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    await appState.db!.rawUpdate(
        'UPDATE news SET status = ? WHERE newsId = ?', [status, newsID]);
  }
  if (appState.debugMode) {
    logThis('updateNewsStatusInDB', 'Finished updating news status in DB',
        LogLevel.INFO);
  }
}

// update the counter of the bookmarked news
void updateStarredCounter(FluxNewsState appState, BuildContext context) async {
  FluxNewsCounterState appCounterState = context.read<FluxNewsCounterState>();
  if (appState.debugMode) {
    logThis('updateNewsStatusInDB', 'Starting updating starred counter',
        LogLevel.INFO);
  }

  int? starredNewsCount;
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    starredNewsCount = Sqflite.firstIntValue(await appState.db!
        .rawQuery('SELECT COUNT(*) FROM news WHERE starred = ?', [1]));
  }
  starredNewsCount ??= 0;
  // assign the count of bookmarked news to the app state variable
  appCounterState.starredCount = starredNewsCount;
  if (context.mounted) {
    if (appState.appBarText == AppLocalizations.of(context)!.bookmarked) {
      // if the bookmarked news are selected to display, assign the count
      // also to the app bar counter variable.
      appCounterState.appBarNewsCount = starredNewsCount;
    }
  }

  if (appState.debugMode) {
    logThis('updateNewsStatusInDB', 'Finished updating starred counter',
        LogLevel.INFO);
  }
  appCounterState.refreshView();
}

// update the bookmarked flag in the database
void updateNewsStarredStatusInDB(
    int newsID, bool starred, FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('updateNewsStarredStatusInDB',
        'Starting updating news starred status in DB', LogLevel.INFO);
  }

  int starredStatus = 0;
  if (starred) {
    starredStatus = 1;
  }
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    await appState.db!.rawUpdate('UPDATE news SET starred = ? WHERE newsId = ?',
        [starredStatus, newsID]);
  }

  if (appState.debugMode) {
    logThis('updateNewsStarredStatusInDB',
        'Finished updating news starred status in DB', LogLevel.INFO);
  }
}

// delete the not bookmarked news, which are beyond the limit of news
// which should be saved locally.
// this limit can be changed in the settings.
Future<void> cleanUnstarredNews(FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('cleanUnstarredNews', 'Starting cleaning unstarred news',
        LogLevel.INFO);
  }

  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    await appState.db!.rawDelete('''DELETE FROM news 
                        WHERE starred = 0 AND newsID NOT IN 
                          (SELECT newsID 
                            FROM news 
                            WHERE starred = 0
                            ORDER BY publishedAt DESC
                            LIMIT ${appState.amountOfSavedNews})''');
  }

  if (appState.debugMode) {
    logThis('cleanUnstarredNews', 'Finished cleaning unstarred news',
        LogLevel.INFO);
  }
}

// delete the bookmarked news, which are beyond the limit of news
// which should be saved locally.
// this limit can be changed in the settings.
// maybe the bookmarked news should have another limit as the not bookmarked news
Future<void> cleanStarredNews(FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis(
        'cleanStarredNews', 'Starting cleaning starred news', LogLevel.INFO);
  }

  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    await appState.db!.rawDelete('''DELETE FROM news 
                        WHERE starred = 1 AND newsID NOT IN 
                          (SELECT newsID 
                            FROM news 
                            WHERE starred = 1
                            ORDER BY publishedAt DESC
                            LIMIT ${appState.amountOfSavedStarredNews})''');
  }

  if (appState.debugMode) {
    logThis(
        'cleanStarredNews', 'Finished cleaning starred news', LogLevel.INFO);
  }
}

// insert the fetched categories in the database
Future<int> insertCategoriesInDB(
    Categories categoryList, FluxNewsState appState) async {
  if (appState.debugMode) {
    logThis('insertCategoriesInDB', 'Starting inserting categories in DB',
        LogLevel.INFO);
  }

  int result = 0;
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    List<Map<String, Object?>> resultSelect = [];
    for (Category category in categoryList.categories) {
      // iterate over the categories and check if they already exists locally.
      resultSelect = await appState.db!.rawQuery(
          'SELECT * FROM categories WHERE categoryID = ?',
          [category.categoryID]);
      if (resultSelect.isEmpty) {
        // if they don't exists locally, insert the category
        result = await appState.db!.insert('categories', category.toMap());
        if (appState.debugMode) {
          logThis(
              'insertCategoriesInDB',
              'Inserted category with id ${category.categoryID} in DB',
              LogLevel.INFO);
        }
      } else {
        // if they exists locally, update the category
        result = await appState.db!.rawUpdate(
            'UPDATE categories SET title = ? WHERE categoryID = ?',
            [category.title, category.categoryID]);
        if (appState.debugMode) {
          logThis(
              'insertCategoriesInDB',
              'Updated category with id ${category.categoryID} in DB',
              LogLevel.INFO);
        }
      }
      for (Feed feed in category.feeds) {
        // iterate over the feeds of the category and check if they already exists locally
        resultSelect = await appState.db!
            .rawQuery('SELECT * FROM feeds WHERE feedID = ?', [feed.feedID]);
        if (resultSelect.isEmpty) {
          // if they don't exists locally, insert the feed
          result = await appState.db!.rawInsert(
              'INSERT INTO feeds (feedID, title, site_url, icon, iconMimeType, newsCount, categoryID) VALUES(?,?,?,?,?,?,?)',
              [
                feed.feedID,
                feed.title,
                feed.siteUrl,
                feed.icon,
                feed.iconMimeType,
                feed.newsCount,
                category.categoryID
              ]);
          if (appState.debugMode) {
            logThis('insertCategoriesInDB',
                'Inserted feed with id ${feed.feedID} in DB', LogLevel.INFO);
          }
        } else {
          // if they exists locally, update the feed
          result = await appState.db!.rawUpdate(
              'UPDATE feeds SET title = ?, site_url = ?, icon = ?, iconMimeType = ?, newsCount = ?, categoryID = ? WHERE feedID = ?',
              [
                feed.title,
                feed.siteUrl,
                feed.icon,
                feed.iconMimeType,
                feed.newsCount,
                category.categoryID,
                feed.feedID
              ]);
          if (appState.debugMode) {
            logThis('insertCategoriesInDB',
                'Updated feed with id ${feed.feedID} in DB', LogLevel.INFO);
          }
        }
      }
    }

    // check if the local categories exists in the fetched categories.
    // if they don't exists, the category is deleted and needs also to be deleted locally
    List<Category> existingCategories = [];
    // get a list of the local categories
    resultSelect = await appState.db!.rawQuery('SELECT * FROM categories');
    if (resultSelect.isNotEmpty) {
      existingCategories =
          resultSelect.map((e) => Category.fromMap(e)).toList();
    }

    for (Category category in existingCategories) {
      // check if the local categories exists in the fetched list of categories
      if (!categoryList.categories
          .any((item) => item.categoryID == category.categoryID)) {
        result = await appState.db!.rawDelete(
            'DELETE FROM categories WHERE categoryID = ?',
            [category.categoryID]);
        if (appState.debugMode) {
          logThis(
              'insertCategoriesInDB',
              'Deleted category with id ${category.categoryID} in DB',
              LogLevel.INFO);
        }
      }
    }

    // check if the local feeds exists in the fetched feeds.
    // if they don't exists, the feed is deleted and needs also to be deleted locally
    List<Feed> existingFeeds = [];
    bool feedFound = false;
    // get a list of the local feeds
    resultSelect = await appState.db!.rawQuery('SELECT * FROM feeds');
    if (resultSelect.isNotEmpty) {
      existingFeeds = resultSelect.map((e) => Feed.fromMap(e)).toList();
    }

    for (Feed feed in existingFeeds) {
      feedFound = false;
      for (Category category in categoryList.categories) {
        // check if the local feed exists in the fetched list of feeds
        if (category.feeds.any((item) => item.feedID == feed.feedID)) {
          feedFound = true;
        }
      }
      if (feedFound == false) {
        // if the feed doesn't exists, delete the feed and all the news of the feed.
        // this is because the feed seems to be deleted on the miniflux server.
        result = await appState.db!
            .rawDelete('DELETE FROM feeds WHERE feedID = ?', [feed.feedID]);
        result = await appState.db!
            .rawDelete('DELETE FROM news WHERE feedID = ?', [feed.feedID]);
        if (appState.debugMode) {
          logThis(
              'insertCategoriesInDB',
              'Deleted news and feed with id ${feed.feedID} in DB',
              LogLevel.INFO);
        }
      }
    }
  }
  if (appState.debugMode) {
    logThis('insertCategoriesInDB', 'Finished inserting categories in DB',
        LogLevel.INFO);
  }
  return result;
}

// get the categories from the database and calculate the news count of this categories
Future<Categories> queryCategoriesFromDB(
    FluxNewsState appState, BuildContext context) async {
  if (appState.debugMode) {
    logThis('queryCategoriesFromDB', 'Starting querying categories from DB',
        LogLevel.INFO);
  }

  List<Category> categoryList = [];
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    // get the categories from the database
    List<Map<String, Object?>> queryResult =
        await appState.db!.rawQuery('SELECT * FROM categories');
    categoryList = queryResult.map((e) => Category.fromMap(e)).toList();
    for (Category category in categoryList) {
      List<Feed> feedList = [];
      queryResult = await appState.db!.rawQuery(
          'SELECT * FROM feeds WHERE categoryID = ?', [category.categoryID]);
      feedList = queryResult.map((e) => Feed.fromMap(e)).toList();
      category.feeds = feedList;
    }
  }
  Categories categories = Categories(categories: categoryList);
  // calculate the news count of the categories and feeds

  if (context.mounted) {
    categories.renewNewsCount(appState, context);
    // calculate the news count of the "all news" section
    renewAllNewsCount(appState, context);
  }
  if (appState.debugMode) {
    logThis('queryCategoriesFromDB', 'Finished querying categories from DB',
        LogLevel.INFO);
  }
  return categories;
}

// calculate the news count of the "all news" section
Future<void> renewAllNewsCount(
    FluxNewsState appState, BuildContext context) async {
  FluxNewsCounterState appCounterState = context.read<FluxNewsCounterState>();
  if (appState.debugMode) {
    logThis(
        'renewAllNewsCount', 'Starting renewing all news count', LogLevel.INFO);
  }
  appState.db ??= await appState.initializeDB();
  int? allNewsCount = 0;
  if (appState.db != null) {
    // decide if the news count should be calculated over all news
    // or only over the unread news.
    String status = '';
    if (appState.newsStatus == FluxNewsState.allNewsString) {
      status = FluxNewsState.databaseAllString;
    } else {
      status = appState.newsStatus;
    }
    allNewsCount = Sqflite.firstIntValue(await appState.db!
        .rawQuery('SELECT COUNT(*) FROM news WHERE status LIKE ?', [status]));
    allNewsCount ??= 0;
  }

  // assign the count of all news to the app state variable
  appCounterState.allNewsCount = allNewsCount;
  if (context.mounted) {
    if (appState.appBarText == AppLocalizations.of(context)!.allNews) {
      // if "all news" are selected to display, assign the count
      // also to the app bar counter variable.
      appCounterState.appBarNewsCount = allNewsCount;
    }
  }
  if (appState.debugMode) {
    logThis(
        'renewAllNewsCount', 'Finished renewing all news count', LogLevel.INFO);
  }

  // notify the app about the updated count of news
  appCounterState.refreshView();
}

// calculate the news count of the "all news" section
Future<void> deleteLocalNewsCache(
    FluxNewsState appState, BuildContext context) async {
  if (appState.debugMode) {
    logThis('deleteLocalNewsCache', 'Starting deleting the local news cache',
        LogLevel.INFO);
  }
  appState.db ??= await appState.initializeDB();
  if (appState.db != null) {
    // create the table news
    await appState.db!.execute('DROP TABLE IF EXISTS news');
    await appState.db!.execute(
      '''CREATE TABLE news(newsID INTEGER PRIMARY KEY, 
                          feedID INTEGER, 
                          title TEXT, 
                          url TEXT, 
                          content TEXT, 
                          hash TEXT, 
                          publishedAt TEXT, 
                          createdAt TEXT, 
                          status TEXT, 
                          readingTime INTEGER, 
                          starred INTEGER, 
                          feedTitle TEXT, 
                          syncStatus TEXT)''',
    );
    // create the table categories
    await appState.db!.execute('DROP TABLE IF EXISTS categories');
    await appState.db!.execute(
      '''CREATE TABLE categories(categoryID INTEGER PRIMARY KEY, 
                          title TEXT)''',
    );
    // create the table feeds
    await appState.db!.execute('DROP TABLE IF EXISTS feeds');
    await appState.db!.execute(
      '''CREATE TABLE feeds(feedID INTEGER PRIMARY KEY, 
                          title TEXT, 
                          site_url TEXT, 
                          icon BLOB,
                          iconMimeType TEXT,
                          newsCount INTEGER,
                          categoryID INTEGER)''',
    );
    // create the table attachments
    await appState.db!.execute('DROP TABLE IF EXISTS attachments');
    await appState.db!.execute(
      '''CREATE TABLE attachments(attachmentID INTEGER PRIMARY KEY, 
                          newsID INTEGER, 
                          attachmentURL TEXT, 
                          attachmentMimeType TEXT)''',
    );
  }
  if (appState.debugMode) {
    logThis('deleteLocalNewsCache', 'Finished deleting the local news cache',
        LogLevel.INFO);
  }
}
