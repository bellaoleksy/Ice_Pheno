# This file pulls data in from NWIS as well as CSV files located in "Input_Files"
# Variables for joined data and joined trimmed data are created here

# Libraries:
library(pacman)
p_load(dplyr,dataRetrieval,lubridate,tidyr,ggplot2,viridis,readxl,imputeTS,tsibble,sjPlot,pROC,gridExtra,broom,gtsummary)

# Sourcing functions needed for trimming data:
source("Input_Files/00_functions.R")
# randomly chosen things below
set.seed(10)

######## Pulling in outlet flow from NWIS and adding cumulative flow:
# LV Site Number:
lv_no <- '401733105392404'

# define parameter for discharge (00060)
param <- '00060'

# get daily values from NWIS
lv_dat <- readNWISdv(siteNumbers = lv_no, parameterCd = param,
                     startDate = '1983-10-01', endDate = '2024-09-30')

# rename columns using renameNWISColumns from package dataRetrieval
# this renames the column for Flow from the parameter ID to "Flow"
lv_dat <- renameNWISColumns(lv_dat)

# Removing column with USGS code for observations
lv_dat <- select(lv_dat, -contains('_cd'))

# Adding the water year to the df
lv_dat <- addWaterYear(lv_dat)

# calculating cumulative discharge for each year by first grouping by water year,
# and then using the "cumsum" function. Add day of water year for plotting purposes.
cumulative_dat <- group_by(lv_dat, waterYear) %>%
  mutate(cumulative_dis = cumsum(Flow), 
         wy_doy = seq(1:n()))

# ungroup the dataframe
cumulative_dat_ungroup <- cumulative_dat %>%
  ungroup() %>%
  as.data.frame()

# rename the df, remove the site number column, make sure dates are in date format. This is the final df
cumulative_flow_df <- cumulative_dat_ungroup %>% select(-site_no) %>% mutate(Date = as.Date(Date, tz = "MST", format = "%Y-%m-%d"))



######## Pulling in Temp and Conductivity from NWIS:
# setting parameters for temp and cond
parameterCd <- c('00095','00010')
# making the request from NWIS
lv_dat_outlet_input <- readWQPqw(paste0("USGS-", lv_no), parameterCd)

#Clean up dataframe
lv_dat_outlet <- lv_dat_outlet_input %>%
  select(ActivityStartDate, ActivityConductingOrganizationText, CharacteristicName, ResultMeasureValue) %>%
  pivot_wider(names_from = CharacteristicName, values_from = ResultMeasureValue, values_fn = mean) %>%
  rename(cond_uScm="Specific conductance",
         temperature_C_raw="Temperature, water",
         Date = "ActivityStartDate") %>%
  select(-ActivityConductingOrganizationText) %>%
  mutate(wy_doy = hydro.day(Date)) %>%
  addWaterYear() %>% 
  distinct(Date, .keep_all = TRUE) %>%
  as_tsibble(., key = waterYear, index = Date) %>% #time series tibble
  fill_gaps() #%>%  #makes the missing data implicit
# View(lv_dat_outlet) # This is weekly data from 1982-2023, but missing temp & cond after 2019

######## Pulling in Daily Temp and Cond from Graham with USGS:
# These CSVs contain data from 2019-2023
out_cond_dat <- read.csv("Input_Files/Loch_O_daily_conductivity.csv")
out_temp_dat <- read.csv("Input_Files/Loch_O_daily_temperature.csv")
# Joining those two using FULL join because there are less conductivity observations
out_condTemp_dat19_23 <- full_join(out_cond_dat,out_temp_dat, by = "Date")
# This CSV contains data from 2011-2019
out_condTemp_dat11_19 <- read.csv("Input_Files/LochDaily_TempCond_2011-2019.csv")
#View(out_condTemp_dat11_19)

out_condTemp_allDates <- merge(out_condTemp_dat11_19, out_condTemp_dat19_23, all = TRUE)
#View(out_condTemp_allDates)

# Adding water year and water year doy to the daily data
out_cond_temp_daily <- out_condTemp_allDates %>% mutate(Date = as.Date(Date, tz = "MST", format = "%Y-%m-%d")) %>% mutate(wy_doy = hydro.day(Date)) %>% addWaterYear() %>% 
  distinct(Date, .keep_all = TRUE)
#View(out_cond_temp_daily)


###### Subsetting weekly temp and cond observations from the daily observations to fill in gap from 2019 onwards
# Create a weekly dataset from the WY2020-2024 data
TLoch_weekly_19_23 <- out_cond_temp_daily %>% 
  mutate(dayOfWeek = wday(Date, label = TRUE, abbr = FALSE)) %>% 
  filter(dayOfWeek == "Tuesday")
TLoch_weekly_19_23<- TLoch_weekly_19_23 %>% select(-dayOfWeek) %>% rename(temperature_C_raw = Temperature_C)

# Joining weekly data from 2019-2023 with the weekly data from 1982-2023 to fill gaps:
updated_lv_dat_outlet <- lv_dat_outlet %>%
  left_join(TLoch_weekly_19_23, by = "Date", suffix = c("_old", "_new")) %>%
  mutate(
    # Replace missing values in lv_dat_outlet with values from TLoch_weekly_19_23
    temperature_C_raw = ifelse(is.na(temperature_C_raw_old), temperature_C_raw_new, temperature_C_raw_old),
    cond_uScm = ifelse(is.na(cond_uScm_old), cond_uScm_new, cond_uScm_old)
  ) %>%
  # Keep only original column names
  select(Date, temperature_C_raw, cond_uScm)

TCond_weekly_all <- updated_lv_dat_outlet %>% mutate(wy_doy = hydro.day(Date)) %>% rename(waterYear = waterYear_old, temperature_C_weekly = temperature_C_raw,cond_uScm_weekly=cond_uScm)
##### THIS IS WEEKLY DATA WITH FILLED GAPS FOR THE ENTIRE TIME SERIES (1982-2023) - TCond_weekly_all

# Filling gaps in weekly data with a max gap of interpolation as 7 days
TCond_imputed_all <- TCond_weekly_all %>%
  mutate(cond_uScm_impute = imputeTS::na_interpolation(cond_uScm_weekly, maxgap = 7),
         temperature_C_impute = imputeTS::na_interpolation(temperature_C_weekly, maxgap = 7))
#### THIS IS THE IMPUTED DATA FOR THE ENTIRE TIME SERIES (1982-2023) - TCond_imputed_all

# Binding the weekly data and imputed data with cumulative flow
## Weekly:
flow_temp_cond_weekly <- full_join(cumulative_flow_df, TCond_weekly_all, by = "Date")
#View(flow_temp_cond_weekly)
## Imputed:
flow_temp_cond_impute <- full_join(cumulative_flow_df, TCond_imputed_all, by = "Date")
#View(flow_temp_cond_impute)



######## Bring in OBSERVED ice presence on The Loch

# this is just the observed ice-off dates from 2013-2023 with date of ice-off, date, and waterYear
obs_ice_off_dates <- read_xlsx("Input_Files/ice_off_dates20240918.xlsx")
#View(obs_ice_off_dates)

# this is just the observed ice-on dates from 2013-2023 with date of ice-off, date, and waterYear
obs_ice_on_dates <- read_xlsx("Input_Files/ice_on_dates_20250414.xlsx") %>%
  mutate(doy = yday(Date))
#View(obs_ice_on_dates)

# this is a df with the wy_doy date of 100% ice and the wy_doy date with 0% ice for 2013-2023
obs_ice_melt_windows <- read_xlsx("Input_Files/ice_100_to_0_dates_20241114.xlsx")
#View(obs_ice_melt_windows)

# Reading CSV for ice duration with 0% ice as ice-off
ice_off_binary <- read.csv("Input_Files/binary_iceOff_20241001.csv")  %>% select(c(Date,ice.0.1.,wy_doy)) %>% rename(ice_or_no=ice.0.1.) %>% mutate(Date = mdy(Date))
# View(ice_off_binary)

# recode ice_or_no into 2 classes
ice_off_binary$ice_presence <- ifelse(ice_off_binary$ice_or_no == 0,
                                      0,
                                      1
)
# set labels for ice
ice_off_binary$ice_presence <- factor(ice_off_binary$ice_presence,
                                      levels = c(1, 0),
                                      labels = c("ice", "no ice")
)

#View(ice_off_binary)
#str(ice_off_binary$ice_presence)
#levels(ice_off_binary$ice_presence)

# making a df for only ice_presence and Date for simpler joining
ice_presence_df <- ice_off_binary %>% select(Date, ice_or_no, ice_presence)

######## Combining Dfs:
# combine binary ice on or off with DAILY temp and conductivity
out_dat_and_ice_daily <- full_join(out_cond_temp_daily,ice_presence_df, by = "Date")
#View(out_dat_and_ice_daily)

# combine daily conductivity and temperature with ice presence and cumulative flow
## This df will be used in models for daily observations. It is trimmed to only include observations that are inside
## the time frame of ice observations -> (drop_na(ice_or_no))
flow_temp_cond_daily_ice <- left_join(out_dat_and_ice_daily,cumulative_flow_df,by="Date") %>% select(-c(wy_doy.y,waterYear.y)) %>% rename(c(wy_doy = wy_doy.x,waterYear = waterYear.x)) %>% drop_na(ice_or_no)
#View(flow_temp_cond_daily_ice)

# combine weekly conductivity and temperature observations with ice presence (this includes cumulative flow already)
flow_temp_cond_weekly_ice <- full_join(flow_temp_cond_weekly, ice_presence_df, by = "Date") %>% select(Date, wy_doy.x, waterYear.x, Flow, cumulative_dis, cond_uScm_weekly, temperature_C_weekly, ice_or_no,ice_presence) %>% rename(wy_doy=wy_doy.x,waterYear=waterYear.x)
#View(flow_temp_cond_weekly_ice)

# combine imputed conductivity and temperature observations with ice presence (this includes cumulative flow already)
flow_temp_cond_imputed_ice <- full_join(flow_temp_cond_impute, ice_presence_df, by = "Date") %>% select(Date, wy_doy.x, waterYear.x, Flow, cumulative_dis, cond_uScm_impute, temperature_C_impute, ice_or_no,ice_presence) %>% rename(wy_doy=wy_doy.x,waterYear=waterYear.x)
#View(flow_temp_cond_imputed_ice)


######## Trimming Dfs for the spring

# trimming the data frames for windows:
## 1982 - 2024
imputed_data_trimmed <- filter_by_year_and_doy(flow_temp_cond_imputed_ice, c(170,288)) # March 18 - July 15
## 1982-2024
weekly_data_trimmed <- filter_by_year_and_doy(flow_temp_cond_weekly_ice, c(170,288)) # March 18 - July 15
## 2014-2023
daily_data_trimmed <- filter_by_year_and_doy(flow_temp_cond_daily_ice, c(170,288)) # March 18 - July 15

####### Trimming Dfs for winter

## 1982 - 2024
oct_dec_impute <- filter_by_year_and_doy(flow_temp_cond_imputed_ice, c(1,76)) # October 1 - December 15
## 1982-2024
oct_dec_weekly <- filter_by_year_and_doy(flow_temp_cond_weekly_ice, c(1,76)) # October 1 - December 15
## 2014-2023
oct_dec_daily <- filter_by_year_and_doy(flow_temp_cond_daily_ice, c(1,76)) # October 1 - December 15

## 1982 - 2024
sept_oct_impute <- filter_by_year_and_doy(flow_temp_cond_imputed_ice, c(349,365)) # September 15 - October 1
## 1982-2024
sept_oct_weekly <- filter_by_year_and_doy(flow_temp_cond_weekly_ice, c(349,365)) # September 15 - October 1
## 2014-2023
sept_oct_daily <- filter_by_year_and_doy(flow_temp_cond_daily_ice, c(349,365)) # September 15 - October 1

# binding all dates
sept_dec_impute <- rbind(sept_oct_impute,oct_dec_impute)

sept_dec_weekly <- rbind(sept_oct_weekly,oct_dec_weekly)

sept_dec_daily <- rbind(sept_oct_daily,oct_dec_daily)

# sorting dates - creating ordered indices for dates
ordered_indices_impute <- order(sept_dec_impute$Date)
ordered_indices_weekly <- order(sept_dec_weekly$Date)
ordered_indices_daily <- order(sept_dec_daily$Date)
# applying indices to data frames:
imputed_data_trimmed_winter <- sept_dec_impute[ordered_indices_impute, ]
weekly_data_trimmed_winter <- sept_dec_weekly[ordered_indices_weekly, ]
daily_data_trimmed_winter <- sept_dec_daily[ordered_indices_daily, ]


####### Trimming Dfs again to match daily variables for model comparison (training time-frame)

# imputed un-trimmed:
flow_temp_cond_imputed_ice_14_23 <- flow_temp_cond_imputed_ice %>% filter(waterYear >= 2014 & waterYear <= 2023)
# weekly un-trimmed:
flow_temp_cond_weekly_ice_14_23 <- flow_temp_cond_weekly_ice %>% filter(waterYear >= 2014 & waterYear <= 2023)

# imputed spring trimmed:
imputed_data_trimmed_14_23 <- imputed_data_trimmed %>% filter(waterYear >= 2014 & waterYear <= 2023)
# weekly spring trimmed:
weekly_data_trimmed_14_23 <- weekly_data_trimmed %>% filter(waterYear >= 2014 & waterYear <= 2023)

# imputed winter trimmed:
imputed_data_trimmed_14_23_winter <- imputed_data_trimmed_winter %>% filter(waterYear >= 2014 & waterYear <= 2023)
# weekly winter trimmed:
weekly_data_trimmed_14_23_winter <- weekly_data_trimmed_winter %>% filter(waterYear >= 2014 & waterYear <= 2023)

####### Randomly sampling 60% of the data with observed ice presence:
# choosing random years for the training and validation datasets:
obs_years_list <- as_tibble(unique(imputed_data_trimmed_14_23$waterYear))
randomYears <- obs_years_list %>% slice_sample(n=6)

# filtering imputed data into training dataset:
imputed_test_df <- imputed_data_trimmed_14_23 %>% filter(waterYear %in% randomYears$value)
#View(imputed_test_df)

# filtering imputed data into validation dataset:
imputed_validation_df <- imputed_data_trimmed_14_23 %>% filter(!(waterYear %in% randomYears$value))
#View(imputed_validation_df)

# filtering weekly data into training dataset:
weekly_test_df <- weekly_data_trimmed_14_23 %>% filter(waterYear %in% randomYears$value)


# filtering weekly data into validation dataset:
weekly_validation_df <- weekly_data_trimmed_14_23 %>% filter(!(waterYear %in% randomYears$value))

# filtering daily data into training dataset
daily_test_df <- daily_data_trimmed %>% filter(waterYear %in% randomYears$value)

# filtering daily data into validation dataset:
daily_validation_df <- daily_data_trimmed %>% filter(!(waterYear %in% randomYears$value))

####### Final Models:
daily_final_model_test <- glm(ice_presence~cumulative_dis+Temperature_C, data = daily_test_df, family = binomial)

weekly_final_model_test <- glm(ice_presence~cumulative_dis+temperature_C_weekly, data = weekly_test_df, family = binomial)

imputed_final_model_test <- glm(ice_presence~cumulative_dis+temperature_C_impute, data = imputed_test_df, family = binomial)

##### Pierson Dates:
pierson_dates <- read_xlsx("Input_Files/Peirson_IcePhenoDates_AVG_20250120.xlsx")
pierson_dates <- pierson_dates %>% mutate(Ice_Off_Peirson = as.Date(Ice_Off_Peirson)) %>%  mutate(wy_doy_pierson_off = hydro.day(Ice_Off_Peirson))
pierson_dates <- pierson_dates %>% mutate(Ice_On_Peirson = as.Date(Ice_On_Peirson)) %>%  mutate(wy_doy_pierson_on = hydro.day(Ice_On_Peirson))
  

##### Daily Weather Stuff:

# Bear Lake Snow Telemetry Data:
SWE_stats <- read.csv("Input_Files/Bear_SWE_stats.csv")

# Weather station data (temp, wind):
weatherData <- read.csv("Input_Files/subdaily_met_1991to2022.csv") %>% select(date_time, waterYear, T_air_2_m, T_air_6_m, WSpd_2_m, WSpd_6_m, SWin_2m6m_mean)

# hindcasted dates of ice-off
hindcasted_dates <- read.csv("Input_Files/hindcasted_ice_off_dates.csv") %>% select(-"X")

# hindcasted dates and SWE
hindcast_SWE <- full_join(SWE_stats,hindcasted_dates, by="waterYear") %>% rename(predicted_ice_off_wy_doy=first_no_ice_wy_doy)

## Weather needs to be daily - here I find the mean daily air temp and wind speed
weather_daily <- weatherData %>%
  mutate(Date = as.Date(date_time)) %>% # Extract the date part
  group_by(Date) %>% # Group by date
  summarise(
    T_air_2_m_mean = mean(T_air_2_m, na.rm = TRUE),
    # T_air_6_m_mean = mean(T_air_6_m, na.rm = TRUE),
    T_air_2_m_max = max(T_air_2_m, na.rm = TRUE),
    T_air_2_m_min = min(T_air_2_m, na.rm = TRUE),
    # T_air_6_m_max = max(T_air_6_m, na.rm = TRUE),
    # T_air_6_m_min = min(T_air_6_m, na.rm = TRUE),
    WSpd_2_m_mean = mean(WSpd_2_m, na.rm = TRUE),
    # WSpd_6_m_mean = mean(WSpd_6_m, na.rm = TRUE),
    SWin_2m6m_daily_mean = mean(SWin_2m6m_mean, na.rm = TRUE)
  ) %>% addWaterYear()


met_and_hydro_winter <- left_join(oct_dec_daily,weather_daily,by="Date") %>% select(-waterYear.y) %>% rename(waterYear=waterYear.x)
met_and_hydro_sep_dec <- left_join(daily_data_trimmed_winter,weather_daily,by="Date") %>% select(-waterYear.y) %>% rename(waterYear=waterYear.x)
